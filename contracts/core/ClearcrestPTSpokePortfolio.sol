// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/IClearcrestSpoke.sol";
import "../interfaces/IPendlePtOracle.sol";

/// @title ClearcrestPTSpokePortfolio
/// @notice Ethereum spoke that holds Pendle PT directly and reports a
///         conservative USDC NAV to the Base hub using the existing spoke tuple.
///         The PT market/router are constructor parameters so this can roll to
///         newer sUSDe maturities as Pendle lists them.
contract ClearcrestPTSpokePortfolio is IClearcrestSpoke, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant PAR = 1e18;

    uint64 public immutable sourceChainId;
    IERC20Metadata public immutable pt;
    IERC20 public immutable usdc;
    address public immutable pendleMarket;
    IPendlePtOracle public immutable ptOracle;
    IChainlinkAggregator public immutable assetUsdFeed;
    uint8 public immutable ptDecimals;
    uint8 public immutable feedDecimals;
    uint32 public immutable twapDuration;

    address public operator;
    address public pendleRouter;
    uint256 public maxStale;
    uint256 public fulfillTimeout;

    uint256 public navUsd18;
    uint256 public reportedAt;
    uint256 public sourceBlockNumber;
    uint64 public nonce;

    struct Claim {
        address recipient;
        uint256 ptAmount;
        uint64 recordedAt;
        bool settled;
    }

    mapping(bytes32 => Claim) public claims;

    event ReportPrepared(uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce);
    event ClaimRecorded(bytes32 indexed claimId, address indexed recipient, uint256 ptAmount);
    event CashFulfilled(bytes32 indexed claimId, address indexed recipient, uint256 ptAmount, uint256 usdcOut);
    event InKindFulfilled(bytes32 indexed claimId, address indexed recipient, uint256 ptAmount);
    event OperatorSet(address indexed operator);
    event PendleRouterSet(address indexed pendleRouter);
    event MaxStaleSet(uint256 maxStale);
    event FulfillTimeoutSet(uint256 fulfillTimeout);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error OnlyOperator();
    error InvalidChainId();
    error InvalidTwapDuration();
    error StalePrice(address feed);
    error InvalidPrice(address feed);
    error UnknownClaim(bytes32 claimId);
    error AlreadySettled(bytes32 claimId);
    error TimeoutNotReached(bytes32 claimId);
    error SlippageTooHigh(uint256 got, uint256 minOut);

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(
        address owner_,
        address operator_,
        uint64 sourceChainId_,
        address pt_,
        address usdc_,
        address pendleMarket_,
        address ptOracle_,
        address assetUsdFeed_,
        address pendleRouter_,
        uint32 twapDuration_,
        uint256 maxStale_,
        uint256 fulfillTimeout_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || operator_ == address(0) || pt_ == address(0) || usdc_ == address(0)
                || pendleMarket_ == address(0) || ptOracle_ == address(0) || assetUsdFeed_ == address(0)
                || pendleRouter_ == address(0)
        ) revert ZeroAddress();
        if (sourceChainId_ == 0) revert InvalidChainId();
        if (twapDuration_ == 0) revert InvalidTwapDuration();

        sourceChainId = sourceChainId_;
        pt = IERC20Metadata(pt_);
        usdc = IERC20(usdc_);
        pendleMarket = pendleMarket_;
        ptOracle = IPendlePtOracle(ptOracle_);
        assetUsdFeed = IChainlinkAggregator(assetUsdFeed_);
        ptDecimals = IERC20Metadata(pt_).decimals();
        feedDecimals = IChainlinkAggregator(assetUsdFeed_).decimals();
        twapDuration = twapDuration_;
        maxStale = maxStale_;
        fulfillTimeout = fulfillTimeout_;

        operator = operator_;
        pendleRouter = pendleRouter_;
        emit OperatorSet(operator_);
        emit PendleRouterSet(pendleRouter_);
        emit MaxStaleSet(maxStale_);
        emit FulfillTimeoutSet(fulfillTimeout_);
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsUSDC();
    }

    function totalAssetsUSDC() public view returns (uint256) {
        uint256 bal = pt.balanceOf(address(this));
        if (bal == 0) return 0;

        uint256 ptToAsset = ptOracle.getPtToAssetRate(pendleMarket, twapDuration);
        if (ptToAsset > PAR) ptToAsset = PAR;

        uint256 assetUsd = _assetUsd();
        uint256 assetAmount = Math.mulDiv(bal, ptToAsset, PAR);
        return Math.mulDiv(assetAmount, assetUsd * (10 ** USDC_DECIMALS), 10 ** (ptDecimals + feedDecimals));
    }

    function prepareReport() external onlyOperator returns (bytes memory) {
        navUsd18 = totalAssetsUSDC() * 1e12;
        reportedAt = block.timestamp;
        sourceBlockNumber = block.number;
        nonce += 1;

        emit ReportPrepared(navUsd18, reportedAt, sourceBlockNumber, nonce);
        return _encodedReport();
    }

    function buildReport() external view returns (bytes memory) {
        return _encodedReport();
    }

    function recordClaim(bytes32 claimId, address recipient, uint256 ptAmount) external onlyOperator {
        if (recipient == address(0)) revert ZeroAddress();
        if (claims[claimId].recipient != address(0)) revert AlreadySettled(claimId);
        claims[claimId] =
            Claim({recipient: recipient, ptAmount: ptAmount, recordedAt: uint64(block.timestamp), settled: false});
        emit ClaimRecorded(claimId, recipient, ptAmount);
    }

    function sellAndRemit(bytes32 claimId, bytes calldata pendleSwapData, uint256 minUsdcOut)
        external
        onlyOperator
        nonReentrant
        returns (uint256 usdcOut)
    {
        Claim storage claim = _openClaim(claimId);

        IERC20(address(pt)).forceApprove(pendleRouter, claim.ptAmount);
        uint256 beforeUsdc = usdc.balanceOf(address(this));
        (bool ok,) = pendleRouter.call(pendleSwapData);
        require(ok, "pendle swap failed");
        usdcOut = usdc.balanceOf(address(this)) - beforeUsdc;
        if (usdcOut < minUsdcOut) revert SlippageTooHigh(usdcOut, minUsdcOut);

        claim.settled = true;
        usdc.safeTransfer(claim.recipient, usdcOut);
        emit CashFulfilled(claimId, claim.recipient, claim.ptAmount, usdcOut);
    }

    function fulfillInKind(bytes32 claimId) external onlyOperator nonReentrant {
        Claim storage claim = _openClaim(claimId);
        claim.settled = true;
        IERC20(address(pt)).safeTransfer(claim.recipient, claim.ptAmount);
        emit InKindFulfilled(claimId, claim.recipient, claim.ptAmount);
    }

    function claimInKindAfterTimeout(bytes32 claimId) external nonReentrant {
        Claim storage claim = _openClaim(claimId);
        if (block.timestamp < claim.recordedAt + fulfillTimeout) revert TimeoutNotReached(claimId);
        claim.settled = true;
        IERC20(address(pt)).safeTransfer(claim.recipient, claim.ptAmount);
        emit InKindFulfilled(claimId, claim.recipient, claim.ptAmount);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setPendleRouter(address pendleRouter_) external onlyOwner {
        if (pendleRouter_ == address(0)) revert ZeroAddress();
        pendleRouter = pendleRouter_;
        emit PendleRouterSet(pendleRouter_);
    }

    function setMaxStale(uint256 maxStale_) external onlyOwner {
        maxStale = maxStale_;
        emit MaxStaleSet(maxStale_);
    }

    function setFulfillTimeout(uint256 fulfillTimeout_) external onlyOwner {
        fulfillTimeout = fulfillTimeout_;
        emit FulfillTimeoutSet(fulfillTimeout_);
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function _assetUsd() internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = assetUsdFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(address(assetUsdFeed));
        if (updatedAt == 0 || updatedAt > block.timestamp) revert StalePrice(address(assetUsdFeed));
        if (maxStale != 0 && block.timestamp > updatedAt + maxStale) revert StalePrice(address(assetUsdFeed));
        return uint256(answer);
    }

    function _encodedReport() internal view returns (bytes memory) {
        return abi.encode(sourceChainId, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function _openClaim(bytes32 claimId) internal view returns (Claim storage claim) {
        claim = claims[claimId];
        if (claim.recipient == address(0)) revert UnknownClaim(claimId);
        if (claim.settled) revert AlreadySettled(claimId);
    }
}
