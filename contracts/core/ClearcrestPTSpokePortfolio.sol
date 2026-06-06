// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/IClearcrestSpoke.sol";
import "../interfaces/IPendlePtOracle.sol";

/// @title ClearcrestPTSpokePortfolio
/// @notice Source-chain spoke that holds Pendle PT directly and reports a
///         conservative USDC NAV to the Base hub using the existing spoke tuple.
///         Entries are balance-checked after the Pendle router call so PT can
///         only enter at an approved sub-par price / annualized implied APY.
contract ClearcrestPTSpokePortfolio is IClearcrestSpoke, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant PAR = 1e18;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_POSITIONS = 8;

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
    address public claimRecorder;
    address public pendleRouter;
    uint256 public maxStale;
    uint256 public fulfillTimeout;

    uint256 public navUsd18;
    uint256 public reportedAt;
    uint256 public sourceBlockNumber;
    uint64 public nonce;

    struct Position {
        IERC20Metadata pt;
        address pendleMarket;
        IChainlinkAggregator assetUsdFeed;
        uint64 maturity;
        uint256 capUsdc;
        uint8 feedDecimals;
        bool enabled;
    }

    struct BuyConstraints {
        uint256 maxUsdcIn;
        uint256 minPtOut;
        uint256 maxPtPriceUsdc18;
        uint256 minImpliedApyBps;
    }

    struct Claim {
        address recipient;
        uint256 ptAmount;
        uint256 positionId;
        uint64 recordedAt;
        bool settled;
    }

    Position[] private _positions;
    mapping(bytes32 => Claim) public claims;

    event PositionAdded(
        uint256 indexed positionId,
        address indexed pt,
        address indexed pendleMarket,
        address assetUsdFeed,
        uint64 maturity,
        uint256 capUsdc
    );
    event PositionEnabled(uint256 indexed positionId, bool enabled);
    event PositionCapSet(uint256 indexed positionId, uint256 capUsdc);
    event PTBought(
        uint256 indexed positionId,
        address indexed pt,
        uint256 usdcSpent,
        uint256 ptReceived,
        uint256 actualPriceUsdc18,
        uint256 impliedApyBps
    );
    event PTRolled(
        uint256 indexed fromPositionId,
        uint256 indexed toPositionId,
        uint256 usdcReceived,
        uint256 ptReceived,
        uint256 actualPriceUsdc18
    );
    event ReportPrepared(uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce);
    event ClaimRecorded(bytes32 indexed claimId, address indexed recipient, uint256 indexed positionId, uint256 ptAmount);
    event CashFulfilled(bytes32 indexed claimId, address indexed recipient, uint256 ptAmount, uint256 usdcOut);
    event InKindFulfilled(bytes32 indexed claimId, address indexed recipient, uint256 ptAmount);
    event OperatorSet(address indexed operator);
    event ClaimRecorderSet(address indexed claimRecorder);
    event PendleRouterSet(address indexed pendleRouter);
    event MaxStaleSet(uint256 maxStale);
    event FulfillTimeoutSet(uint256 fulfillTimeout);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EmergencyPositionRedeemed(
        uint256 indexed positionId, address indexed receiver, uint256 ptBalanceBefore, uint256 usdcOut
    );
    event EmergencyWithdrawAll(address indexed receiver, uint256 usdcAmount);

    error ZeroAddress();
    error OnlyOperator();
    error OnlyClaimRecorder();
    error InvalidChainId();
    error InvalidTwapDuration();
    error InvalidPosition(uint256 positionId);
    error InvalidMaturity(uint256 maturity);
    error PositionDisabled(uint256 positionId);
    error PositionLimitExceeded();
    error PositionCapExceeded(uint256 positionId, uint256 valueUsdc, uint256 capUsdc);
    error StalePrice(address feed);
    error InvalidPrice(address feed);
    error PriceAboveLimit(uint256 actualPriceUsdc18, uint256 maxPriceUsdc18);
    error PriceNotSubPar(uint256 maxPriceUsdc18);
    error ImpliedApyTooLow(uint256 actualApyBps, uint256 minApyBps);
    error InsufficientPTReceived(uint256 got, uint256 minOut);
    error InsufficientUSDCReceived(uint256 got, uint256 minOut);
    error PositionNotMatured(uint256 positionId, uint256 maturity);
    error UnknownClaim(bytes32 claimId);
    error AlreadySettled(bytes32 claimId);
    error TimeoutNotReached(bytes32 claimId);
    error SlippageTooHigh(uint256 got, uint256 minOut);

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    modifier onlyClaimRecorder() {
        if (msg.sender != claimRecorder) revert OnlyClaimRecorder();
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

        _addPosition(pt_, pendleMarket_, assetUsdFeed_, _deriveMaturity(pendleMarket_), 0);

        operator = operator_;
        claimRecorder = operator_;
        pendleRouter = pendleRouter_;
        emit OperatorSet(operator_);
        emit ClaimRecorderSet(operator_);
        emit PendleRouterSet(pendleRouter_);
        emit MaxStaleSet(maxStale_);
        emit FulfillTimeoutSet(fulfillTimeout_);
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsUSDC();
    }

    function totalAssetsUSDC() public view returns (uint256) {
        uint256 count = _positions.length;
        uint256 totalUsdc;
        for (uint256 i; i < count; ++i) {
            Position storage position = _positions[i];
            if (!position.enabled) continue;

            totalUsdc += _positionValueUSDC(position);
        }
        return totalUsdc;
    }

    function prepareReport() external onlyOperator whenNotPaused returns (bytes memory) {
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

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function positionAt(uint256 positionId)
        external
        view
        returns (
            address positionPt,
            address positionMarket,
            address positionFeed,
            uint64 maturity,
            uint256 capUsdc,
            bool enabled
        )
    {
        Position storage position = _position(positionId);
        return (
            address(position.pt),
            position.pendleMarket,
            address(position.assetUsdFeed),
            position.maturity,
            position.capUsdc,
            position.enabled
        );
    }

    function addPosition(address pt_, address pendleMarket_, uint64 maturity_) external onlyOwner {
        addPositionWithFeed(pt_, pendleMarket_, address(assetUsdFeed), maturity_);
    }

    function addPositionWithFeed(address pt_, address pendleMarket_, address assetUsdFeed_, uint64 maturity_)
        public
        onlyOwner
    {
        addPositionWithFeedAndCap(pt_, pendleMarket_, assetUsdFeed_, maturity_, 0);
    }

    function addPositionWithFeedAndCap(
        address pt_,
        address pendleMarket_,
        address assetUsdFeed_,
        uint64 maturity_,
        uint256 capUsdc_
    ) public onlyOwner {
        if (maturity_ <= block.timestamp) revert InvalidMaturity(maturity_);
        _addPosition(pt_, pendleMarket_, assetUsdFeed_, maturity_, capUsdc_);
    }

    function setPositionEnabled(uint256 positionId, bool enabled) external onlyOwner {
        Position storage position = _position(positionId);
        position.enabled = enabled;
        emit PositionEnabled(positionId, enabled);
    }

    function setPositionCapUsdc(uint256 positionId, uint256 capUsdc_) external onlyOwner {
        Position storage position = _position(positionId);
        position.capUsdc = capUsdc_;
        _enforcePositionCap(positionId, position);
        emit PositionCapSet(positionId, capUsdc_);
    }

    /// @notice Buy PT through the configured Pendle router while enforcing the
    ///         realised fill is sub-par and meets the requested annualized APY.
    /// @dev `pendleSwapData` must be calldata for `pendleRouter`; the spoke
    ///      measures USDC spent and PT received rather than trusting router data.
    function buyPtWithUsdc(
        uint256 positionId,
        uint256 maxUsdcIn,
        uint256 minPtOut,
        uint256 maxPtPriceUsdc18,
        uint256 minImpliedApyBps,
        bytes calldata pendleSwapData
    ) external onlyOperator nonReentrant returns (uint256 usdcSpent, uint256 ptReceived, uint256 actualPriceUsdc18) {
        return _buyPtWithUsdc(
            positionId,
            BuyConstraints({
                maxUsdcIn: maxUsdcIn,
                minPtOut: minPtOut,
                maxPtPriceUsdc18: maxPtPriceUsdc18,
                minImpliedApyBps: minImpliedApyBps
            }),
            pendleSwapData
        );
    }

    /// @notice Redeem a matured PT position to USDC and immediately roll into a
    ///         new guarded PT purchase. Pendle calldata stays router-specific;
    ///         the spoke enforces maturity, proceeds, and entry price.
    function rollMatured(
        uint256 fromPositionId,
        uint256 toPositionId,
        uint256 minUsdcOut,
        BuyConstraints calldata buyConstraints,
        bytes calldata pendleRedeemData,
        bytes calldata pendleBuyData
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256, uint256, uint256) {
        uint256 usdcReceived = _redeemMaturedPosition(fromPositionId, pendleRedeemData);
        if (usdcReceived < minUsdcOut) revert InsufficientUSDCReceived(usdcReceived, minUsdcOut);

        BuyConstraints memory constraints = BuyConstraints({
            maxUsdcIn: usdcReceived,
            minPtOut: buyConstraints.minPtOut,
            maxPtPriceUsdc18: buyConstraints.maxPtPriceUsdc18,
            minImpliedApyBps: buyConstraints.minImpliedApyBps
        });
        (, uint256 ptReceived, uint256 actualPriceUsdc18) = _buyPtWithUsdc(toPositionId, constraints, pendleBuyData);

        emit PTRolled(fromPositionId, toPositionId, usdcReceived, ptReceived, actualPriceUsdc18);
        return (usdcReceived, ptReceived, actualPriceUsdc18);
    }

    function recordClaim(bytes32 claimId, address recipient, uint256 ptAmount) external onlyClaimRecorder whenNotPaused {
        _recordClaim(claimId, recipient, 0, ptAmount);
    }

    function recordClaimForPosition(bytes32 claimId, address recipient, uint256 positionId, uint256 ptAmount)
        external
        onlyClaimRecorder
        whenNotPaused
    {
        _recordClaim(claimId, recipient, positionId, ptAmount);
    }

    function _recordClaim(bytes32 claimId, address recipient, uint256 positionId, uint256 ptAmount) internal {
        if (recipient == address(0)) revert ZeroAddress();
        _position(positionId);
        if (claims[claimId].recipient != address(0)) revert AlreadySettled(claimId);
        claims[claimId] = Claim({
            recipient: recipient,
            ptAmount: ptAmount,
            positionId: positionId,
            recordedAt: uint64(block.timestamp),
            settled: false
        });
        emit ClaimRecorded(claimId, recipient, positionId, ptAmount);
    }

    function sellAndRemit(bytes32 claimId, bytes calldata pendleSwapData, uint256 minUsdcOut)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
        returns (uint256 usdcOut)
    {
        Claim storage claim = _openClaim(claimId);
        Position storage claimPosition = _position(claim.positionId);

        IERC20(address(claimPosition.pt)).forceApprove(pendleRouter, claim.ptAmount);
        uint256 beforeUsdc = usdc.balanceOf(address(this));
        (bool ok,) = pendleRouter.call(pendleSwapData);
        require(ok, "pendle swap failed");
        IERC20(address(claimPosition.pt)).forceApprove(pendleRouter, 0);
        usdcOut = usdc.balanceOf(address(this)) - beforeUsdc;
        if (usdcOut < minUsdcOut) revert SlippageTooHigh(usdcOut, minUsdcOut);

        claim.settled = true;
        usdc.safeTransfer(claim.recipient, usdcOut);
        emit CashFulfilled(claimId, claim.recipient, claim.ptAmount, usdcOut);
    }

    function fulfillInKind(bytes32 claimId) external onlyOperator whenNotPaused nonReentrant {
        Claim storage claim = _openClaim(claimId);
        Position storage claimPosition = _position(claim.positionId);
        claim.settled = true;
        IERC20(address(claimPosition.pt)).safeTransfer(claim.recipient, claim.ptAmount);
        emit InKindFulfilled(claimId, claim.recipient, claim.ptAmount);
    }

    function claimInKindAfterTimeout(bytes32 claimId) external whenNotPaused nonReentrant {
        Claim storage claim = _openClaim(claimId);
        Position storage claimPosition = _position(claim.positionId);
        if (block.timestamp < claim.recordedAt + fulfillTimeout) revert TimeoutNotReached(claimId);
        claim.settled = true;
        IERC20(address(claimPosition.pt)).safeTransfer(claim.recipient, claim.ptAmount);
        emit InKindFulfilled(claimId, claim.recipient, claim.ptAmount);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setClaimRecorder(address claimRecorder_) external onlyOwner {
        if (claimRecorder_ == address(0)) revert ZeroAddress();
        claimRecorder = claimRecorder_;
        emit ClaimRecorderSet(claimRecorder_);
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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyRedeemPosition(
        uint256 positionId,
        bytes calldata pendleRedeemData,
        uint256 minUsdcOut,
        address receiver
    ) external onlyOwner nonReentrant returns (uint256 usdcOut) {
        if (receiver == address(0)) revert ZeroAddress();
        Position storage position = _position(positionId);

        uint256 ptBalance = position.pt.balanceOf(address(this));
        uint256 beforeUsdc = usdc.balanceOf(address(this));
        IERC20(address(position.pt)).forceApprove(pendleRouter, ptBalance);
        (bool ok,) = pendleRouter.call(pendleRedeemData);
        IERC20(address(position.pt)).forceApprove(pendleRouter, 0);
        require(ok, "pendle emergency redeem failed");

        usdcOut = usdc.balanceOf(address(this)) - beforeUsdc;
        if (usdcOut < minUsdcOut) revert SlippageTooHigh(usdcOut, minUsdcOut);
        usdc.safeTransfer(receiver, usdcOut);
        emit EmergencyPositionRedeemed(positionId, receiver, ptBalance, usdcOut);
    }

    function emergencyWithdrawAll(address receiver) external onlyOwner nonReentrant returns (uint256 usdcAmount) {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 count = _positions.length;
        for (uint256 i; i < count; ++i) {
            IERC20Metadata positionPt = _positions[i].pt;
            uint256 ptBalance = positionPt.balanceOf(address(this));
            if (ptBalance != 0) IERC20(address(positionPt)).safeTransfer(receiver, ptBalance);
        }

        usdcAmount = usdc.balanceOf(address(this));
        if (usdcAmount != 0) usdc.safeTransfer(receiver, usdcAmount);
        emit EmergencyWithdrawAll(receiver, usdcAmount);
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function _assetUsd(IChainlinkAggregator feed) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(address(feed));
        if (updatedAt == 0 || updatedAt > block.timestamp) revert StalePrice(address(feed));
        if (maxStale != 0 && block.timestamp > updatedAt + maxStale) revert StalePrice(address(feed));
        return uint256(answer);
    }

    function _encodedReport() internal view returns (bytes memory) {
        return abi.encode(sourceChainId, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function _buyPtWithUsdc(uint256 positionId, BuyConstraints memory constraints, bytes calldata pendleSwapData)
        internal
        whenNotPaused
        returns (uint256 usdcSpent, uint256 ptReceived, uint256 actualPriceUsdc18)
    {
        Position storage position = _position(positionId);
        if (!position.enabled) revert PositionDisabled(positionId);
        if (block.timestamp >= position.maturity) revert InvalidMaturity(position.maturity);
        if (constraints.maxPtPriceUsdc18 >= PAR) revert PriceNotSubPar(constraints.maxPtPriceUsdc18);

        uint256 beforeUsdc = usdc.balanceOf(address(this));
        uint256 beforePt = position.pt.balanceOf(address(this));

        usdc.forceApprove(pendleRouter, constraints.maxUsdcIn);
        (bool ok,) = pendleRouter.call(pendleSwapData);
        usdc.forceApprove(pendleRouter, 0);
        require(ok, "pendle buy failed");

        usdcSpent = beforeUsdc - usdc.balanceOf(address(this));
        ptReceived = position.pt.balanceOf(address(this)) - beforePt;
        if (ptReceived < constraints.minPtOut) revert InsufficientPTReceived(ptReceived, constraints.minPtOut);

        actualPriceUsdc18 = _ptPriceUsdc18(usdcSpent, ptReceived, position.pt.decimals());
        if (actualPriceUsdc18 > constraints.maxPtPriceUsdc18) {
            revert PriceAboveLimit(actualPriceUsdc18, constraints.maxPtPriceUsdc18);
        }

        uint256 impliedApyBps = _impliedApyBps(actualPriceUsdc18, position.maturity);
        if (impliedApyBps < constraints.minImpliedApyBps) {
            revert ImpliedApyTooLow(impliedApyBps, constraints.minImpliedApyBps);
        }
        _enforcePositionCap(positionId, position);

        emit PTBought(positionId, address(position.pt), usdcSpent, ptReceived, actualPriceUsdc18, impliedApyBps);
    }

    function _redeemMaturedPosition(uint256 positionId, bytes calldata pendleRedeemData)
        internal
        returns (uint256 usdcReceived)
    {
        Position storage fromPosition = _position(positionId);
        if (block.timestamp < fromPosition.maturity) {
            revert PositionNotMatured(positionId, fromPosition.maturity);
        }

        uint256 ptBalance = fromPosition.pt.balanceOf(address(this));
        uint256 beforeUsdc = usdc.balanceOf(address(this));
        IERC20(address(fromPosition.pt)).forceApprove(pendleRouter, ptBalance);
        (bool ok,) = pendleRouter.call(pendleRedeemData);
        IERC20(address(fromPosition.pt)).forceApprove(pendleRouter, 0);
        require(ok, "pendle redeem failed");
        return usdc.balanceOf(address(this)) - beforeUsdc;
    }

    function _ptPriceUsdc18(uint256 usdcSpent, uint256 ptReceived, uint8 decimals_) internal pure returns (uint256) {
        return Math.mulDiv(usdcSpent, 10 ** (uint256(decimals_) + 12), ptReceived);
    }

    function _impliedApyBps(uint256 priceUsdc18, uint256 maturity) internal view returns (uint256) {
        if (priceUsdc18 >= PAR || block.timestamp >= maturity) return 0;
        uint256 secondsToMaturity = maturity - block.timestamp;
        uint256 discount = PAR - priceUsdc18;
        return Math.mulDiv(Math.mulDiv(discount, YEAR, priceUsdc18), BPS_DENOM, secondsToMaturity);
    }

    function _addPosition(address pt_, address pendleMarket_, address assetUsdFeed_, uint64 maturity_, uint256 capUsdc_)
        internal
    {
        if (pt_ == address(0) || pendleMarket_ == address(0) || assetUsdFeed_ == address(0)) revert ZeroAddress();
        if (_positions.length >= MAX_POSITIONS) revert PositionLimitExceeded();
        _positions.push(
            Position({
                pt: IERC20Metadata(pt_),
                pendleMarket: pendleMarket_,
                assetUsdFeed: IChainlinkAggregator(assetUsdFeed_),
                maturity: maturity_,
                capUsdc: capUsdc_,
                feedDecimals: IChainlinkAggregator(assetUsdFeed_).decimals(),
                enabled: true
            })
        );
        emit PositionAdded(_positions.length - 1, pt_, pendleMarket_, assetUsdFeed_, maturity_, capUsdc_);
    }

    function _position(uint256 positionId) internal view returns (Position storage position) {
        if (positionId >= _positions.length) revert InvalidPosition(positionId);
        return _positions[positionId];
    }

    function _positionValueUSDC(Position storage position) internal view returns (uint256) {
        uint256 bal = position.pt.balanceOf(address(this));
        if (bal == 0) return 0;

        uint256 ptToAsset = ptOracle.getPtToAssetRate(position.pendleMarket, twapDuration);
        if (ptToAsset > PAR) ptToAsset = PAR;

        uint256 assetUsd = _assetUsd(position.assetUsdFeed);
        uint256 assetAmount = Math.mulDiv(bal, ptToAsset, PAR);
        return Math.mulDiv(
            assetAmount, assetUsd * (10 ** USDC_DECIMALS), 10 ** (position.pt.decimals() + position.feedDecimals)
        );
    }

    function _enforcePositionCap(uint256 positionId, Position storage position) internal view {
        if (position.capUsdc == 0) return;
        uint256 valueUsdc = _positionValueUSDC(position);
        if (valueUsdc > position.capUsdc) revert PositionCapExceeded(positionId, valueUsdc, position.capUsdc);
    }

    function _deriveMaturity(address market_) internal view returns (uint64 maturity_) {
        (bool ok, bytes memory data) = market_.staticcall(abi.encodeWithSignature("expiry()"));
        if (ok && data.length >= 32) return uint64(abi.decode(data, (uint256)));

        (ok, data) = market_.staticcall(abi.encodeWithSignature("maturity()"));
        if (ok && data.length >= 32) return uint64(abi.decode(data, (uint256)));

        return type(uint64).max;
    }

    function _openClaim(bytes32 claimId) internal view returns (Claim storage claim) {
        claim = claims[claimId];
        if (claim.recipient == address(0)) revert UnknownClaim(claimId);
        if (claim.settled) revert AlreadySettled(claimId);
    }
}
