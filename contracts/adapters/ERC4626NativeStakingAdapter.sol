// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/INativeStakingAdapter.sol";

/// @title ERC4626NativeStakingAdapter
/// @notice Chain-local adapter for native staking wrappers that expose an
///         ERC4626-style vault interface. It values the native asset with a
///         Chainlink USD feed and reports USDC-normalized NAV to the spoke.
contract ERC4626NativeStakingAdapter is INativeStakingAdapter, Ownable2Step {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant DEFAULT_MAX_STALE = 24 hours;

    address public immutable controller;
    IERC20Metadata public immutable assetToken;
    IERC4626 public immutable stakingVault;
    IChainlinkAggregator public immutable priceFeed;
    uint8 public immutable assetDecimals;
    uint8 public immutable feedDecimals;

    uint256 public maxStale;

    event Deployed(uint256 assetAmount);
    event Withdrawn(uint256 requestedAssetAmount, uint256 returnedAssetAmount, address indexed receiver);
    event Harvested(uint256 compoundedAssetValue);
    event EmergencyWithdrawn(uint256 assetReturned, address indexed receiver);
    event MaxStaleUpdated(uint256 maxStale);

    error ZeroAddress();
    error OnlyController();
    error InvalidVaultAsset();
    error StalePrice(address feed);
    error InvalidPrice(address feed);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor(
        address owner_,
        address controller_,
        address asset_,
        address stakingVault_,
        address priceFeed_,
        uint256 maxStale_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || controller_ == address(0) || asset_ == address(0)
                || stakingVault_ == address(0) || priceFeed_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (IERC4626(stakingVault_).asset() != asset_) revert InvalidVaultAsset();

        controller = controller_;
        assetToken = IERC20Metadata(asset_);
        stakingVault = IERC4626(stakingVault_);
        priceFeed = IChainlinkAggregator(priceFeed_);
        assetDecimals = IERC20Metadata(asset_).decimals();
        feedDecimals = IChainlinkAggregator(priceFeed_).decimals();
        maxStale = maxStale_ == 0 ? DEFAULT_MAX_STALE : maxStale_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    /// @notice Stake asset already transferred into this adapter.
    function deploy(uint256 assetAmount) external onlyController {
        if (assetAmount == 0) return;
        assetToken.forceApprove(address(stakingVault), assetAmount);
        stakingVault.deposit(assetAmount, address(this));
        emit Deployed(assetAmount);
    }

    /// @notice Withdraw native asset value back to the spoke/controller.
    function withdraw(uint256 assetAmount, address receiver)
        external
        onlyController
        returns (uint256 assetReturned)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (assetAmount == 0) return 0;

        assetReturned = _useIdle(assetAmount);
        uint256 remaining = assetAmount - assetReturned;

        if (remaining > 0) {
            uint256 beforeBalance = assetToken.balanceOf(address(this));
            uint256 available = stakingVault.convertToAssets(stakingVault.balanceOf(address(this)));
            uint256 request = remaining > available ? available : remaining;
            if (request > 0) {
                stakingVault.withdraw(request, address(this), address(this));
                assetReturned += assetToken.balanceOf(address(this)) - beforeBalance;
            }
        }

        if (assetReturned > assetAmount) assetReturned = assetAmount;
        if (assetReturned > 0) assetToken.safeTransfer(receiver, assetReturned);
        emit Withdrawn(assetAmount, assetReturned, receiver);
    }

    /// @notice ERC4626 staking wrappers compound inside share price, so harvest
    ///         records current compounded asset value without moving funds.
    function harvest() external onlyController returns (uint256 compoundedAssetValue) {
        compoundedAssetValue = totalAssetsAsset();
        emit Harvested(compoundedAssetValue);
    }

    function totalAssetsAsset() public view returns (uint256) {
        return assetToken.balanceOf(address(this)) + stakingVault.convertToAssets(stakingVault.balanceOf(address(this)));
    }

    function totalAssetsUSDC() public view returns (uint256) {
        uint256 price = _latestPrice();
        return Math.mulDiv(totalAssetsAsset(), price * (10 ** USDC_DECIMALS), 10 ** (assetDecimals + feedDecimals));
    }

    function setMaxStale(uint256 newMaxStale) external onlyOwner {
        if (newMaxStale == 0) newMaxStale = DEFAULT_MAX_STALE;
        maxStale = newMaxStale;
        emit MaxStaleUpdated(newMaxStale);
    }

    function emergencyWithdrawAll(address receiver) external onlyOwner returns (uint256 assetReturned) {
        if (receiver == address(0)) revert ZeroAddress();

        uint256 shares = stakingVault.balanceOf(address(this));
        if (shares > 0) {
            stakingVault.redeem(shares, address(this), address(this));
        }

        assetReturned = assetToken.balanceOf(address(this));
        if (assetReturned > 0) assetToken.safeTransfer(receiver, assetReturned);
        emit EmergencyWithdrawn(assetReturned, receiver);
    }

    function _useIdle(uint256 amount) internal view returns (uint256 used) {
        uint256 idle = assetToken.balanceOf(address(this));
        used = idle > amount ? amount : idle;
    }

    function _latestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(address(priceFeed));
        if (block.timestamp > updatedAt + maxStale) revert StalePrice(address(priceFeed));
        return SafeCast.toUint256(answer);
    }
}
