// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/ICamelotRouter.sol";
import "../interfaces/IClearcrestRegistry.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/ISleeveAdapter.sol";

/// @title SleeveABasketAdapter
/// @notice Adapter for Sleeve A's top non-stable crypto basket.
///         The adapter keeps asset selection and weights configurable so the
///         founder/governance-approved policy can update the basket without a
///         redeploy. It swaps USDC into approved assets, values positions using
///         Chainlink-style USD feeds, and unwinds assets pro-rata for vault
///         withdrawals.
contract SleeveABasketAdapter is ISleeveAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_ASSETS = 10;
    uint256 public constant MIN_WEIGHT_BPS = 300; // 3%
    uint256 public constant MAX_WEIGHT_BPS = 3_000; // 30%
    uint256 public constant USDC_DECIMALS = 6;

    struct AssetConfig {
        address token;
        address priceFeed;
        uint16 weightBps;
        uint8 tokenDecimals;
        uint32 maxStale;
    }

    struct AssetInput {
        address token;
        address priceFeed;
        uint16 weightBps;
        uint8 tokenDecimals;
        uint32 maxStale;
        address[] buyPath;
        address[] sellPath;
    }

    struct RegistryAssetInput {
        bytes32 assetId;
        uint16 weightBps;
        uint32 maxStale;
        address[] buyPath;
        address[] sellPath;
    }

    address public immutable vault;
    IERC20 public immutable usdc;
    ICamelotRouter public immutable router;
    IClearcrestRegistry public registry;

    AssetConfig[] private _assets;
    mapping(uint256 => address[]) private _buyPaths;
    mapping(uint256 => address[]) private _sellPaths;
    uint256 public maxSlippageBps = 100; // 1%

    event AssetsConfigured(uint256 count);
    event RegistrySet(address indexed registry);
    event MaxSlippageSet(uint256 maxSlippageBps);
    event Deployed(uint256 usdcAmount);
    event Withdrawn(uint256 requestedUsdc, uint256 returnedUsdc);
    event Harvested(uint256 yieldUsdc);
    event Rebalanced(uint256 navAfter);
    event EmergencyUnwound(uint256 indexed assetIndex, uint256 tokenAmount);
    event EmergencyUnwoundAll();

    error ZeroAddress();
    error OnlyVault();
    error InvalidAssetCount();
    error InvalidWeight();
    error InvalidWeightTotal();
    error DuplicateAsset();
    error InvalidSlippage();
    error InvalidSwapPath();
    error AdapterNotEmpty();
    error AssetNotTrusted(bytes32 assetId);
    error StalePrice(address feed);
    error InvalidPrice(address feed);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @dev L-01: lets `ClearcrestVault.emergencyUnwindSleeves` orchestrate.
    modifier onlyOwnerOrVault() {
        if (msg.sender != owner() && msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _vault, address _owner, address _usdc, address _router) Ownable(_owner) {
        if (_vault == address(0) || _owner == address(0) || _usdc == address(0) || _router == address(0)) {
            revert ZeroAddress();
        }
        vault = _vault;
        usdc = IERC20(_usdc);
        router = ICamelotRouter(_router);
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 index) external view returns (AssetConfig memory) {
        return _assets[index];
    }

    function assetPaths(uint256 index) external view returns (address[] memory buyPath, address[] memory sellPath) {
        return (_buyPaths[index], _sellPaths[index]);
    }

    function assetValueUSDC(uint256 index) external view returns (uint256) {
        return _assetValueUSDC(index);
    }

    function setMaxSlippageBps(uint256 newMaxSlippageBps) external onlyOwner {
        if (newMaxSlippageBps > 1_000) revert InvalidSlippage();
        maxSlippageBps = newMaxSlippageBps;
        emit MaxSlippageSet(newMaxSlippageBps);
    }

    function setRegistry(address newRegistry) external onlyOwner {
        if (_adapterHasValue()) revert AdapterNotEmpty();
        if (newRegistry == address(0)) revert ZeroAddress();
        registry = IClearcrestRegistry(newRegistry);
        emit RegistrySet(newRegistry);
    }

    function setAssets(AssetInput[] calldata newAssets) external onlyOwner {
        if (_adapterHasValue()) revert AdapterNotEmpty();

        uint256 count = newAssets.length;
        if (count == 0 || count > MAX_ASSETS) revert InvalidAssetCount();

        uint256 weightTotal;
        for (uint256 i; i < count; ++i) {
            AssetInput calldata asset = newAssets[i];
            if (asset.token == address(0) || asset.priceFeed == address(0)) revert ZeroAddress();
            if (asset.weightBps < MIN_WEIGHT_BPS || asset.weightBps > MAX_WEIGHT_BPS) revert InvalidWeight();
            if (asset.maxStale == 0) revert StalePrice(asset.priceFeed);
            _validatePaths(asset.token, asset.buyPath, asset.sellPath);

            for (uint256 j = i + 1; j < count; ++j) {
                if (asset.token == newAssets[j].token) revert DuplicateAsset();
            }

            weightTotal += asset.weightBps;
            _validatePrice(asset.priceFeed, asset.maxStale);
        }

        if (weightTotal != BPS_DENOM) revert InvalidWeightTotal();

        for (uint256 i; i < _assets.length; ++i) {
            delete _buyPaths[i];
            delete _sellPaths[i];
        }
        delete _assets;
        for (uint256 i; i < count; ++i) {
            AssetInput calldata input = newAssets[i];
            uint8 tokenDecimals = input.tokenDecimals;
            if (tokenDecimals == 0) {
                tokenDecimals = IERC20Metadata(input.token).decimals();
            }
            _assets.push(
                AssetConfig({
                    token: input.token,
                    priceFeed: input.priceFeed,
                    weightBps: input.weightBps,
                    tokenDecimals: tokenDecimals,
                    maxStale: input.maxStale
                })
            );
            _copyPath(_buyPaths[i], input.buyPath);
            _copyPath(_sellPaths[i], input.sellPath);
        }

        emit AssetsConfigured(count);
    }

    function setAssetsFromRegistry(RegistryAssetInput[] calldata newAssets) external onlyOwner {
        if (address(registry) == address(0)) revert ZeroAddress();
        if (_adapterHasValue()) revert AdapterNotEmpty();

        uint256 count = newAssets.length;
        if (count == 0 || count > MAX_ASSETS) revert InvalidAssetCount();

        AssetInput[] memory resolvedAssets = new AssetInput[](count);
        for (uint256 i; i < count; ++i) {
            RegistryAssetInput calldata input = newAssets[i];
            IClearcrestRegistry.AssetConfig memory config = registry.getAsset(input.assetId);
            if (!config.trusted) revert AssetNotTrusted(input.assetId);

            resolvedAssets[i] = AssetInput({
                token: config.token,
                priceFeed: config.priceFeed,
                weightBps: input.weightBps,
                tokenDecimals: config.tokenDecimals,
                maxStale: input.maxStale,
                buyPath: input.buyPath,
                sellPath: input.sellPath
            });
        }

        _setAssets(resolvedAssets);
    }

    function _setAssets(AssetInput[] memory newAssets) internal {
        uint256 count = newAssets.length;
        if (count == 0 || count > MAX_ASSETS) revert InvalidAssetCount();

        uint256 weightTotal;
        for (uint256 i; i < count; ++i) {
            AssetInput memory asset = newAssets[i];
            if (asset.token == address(0) || asset.priceFeed == address(0)) revert ZeroAddress();
            if (asset.weightBps < MIN_WEIGHT_BPS || asset.weightBps > MAX_WEIGHT_BPS) revert InvalidWeight();
            if (asset.maxStale == 0) revert StalePrice(asset.priceFeed);
            _validatePathsMemory(asset.token, asset.buyPath, asset.sellPath);

            for (uint256 j = i + 1; j < count; ++j) {
                if (asset.token == newAssets[j].token) revert DuplicateAsset();
            }

            weightTotal += asset.weightBps;
            _validatePrice(asset.priceFeed, asset.maxStale);
        }

        if (weightTotal != BPS_DENOM) revert InvalidWeightTotal();

        for (uint256 i; i < _assets.length; ++i) {
            delete _buyPaths[i];
            delete _sellPaths[i];
        }
        delete _assets;
        for (uint256 i; i < count; ++i) {
            AssetInput memory input = newAssets[i];
            uint8 tokenDecimals = input.tokenDecimals;
            if (tokenDecimals == 0) {
                tokenDecimals = IERC20Metadata(input.token).decimals();
            }
            _assets.push(
                AssetConfig({
                    token: input.token,
                    priceFeed: input.priceFeed,
                    weightBps: input.weightBps,
                    tokenDecimals: tokenDecimals,
                    maxStale: input.maxStale
                })
            );
            _copyPathMemory(_buyPaths[i], input.buyPath);
            _copyPathMemory(_sellPaths[i], input.sellPath);
        }

        emit AssetsConfigured(count);
    }

    /// @notice Deploy USDC already transferred to this adapter into the Sleeve A basket.
    function deploy(uint256 usdcAmount) external onlyVault {
        uint256 count = _assets.length;
        if (count == 0) revert InvalidAssetCount();

        uint256 allocated;
        for (uint256 i; i < count; ++i) {
            uint256 amountIn =
                i == count - 1 ? usdcAmount - allocated : Math.mulDiv(usdcAmount, _assets[i].weightBps, BPS_DENOM);
            allocated += amountIn;
            if (amountIn == 0) continue;
            _swap(_buyPaths[i], amountIn, address(this));
        }

        emit Deployed(usdcAmount);
    }

    /// @notice Withdraw USDC-equivalent value by selling positions pro-rata.
    function withdraw(uint256 usdcAmount) external onlyVault returns (uint256 usdcReturned) {
        uint256 navBefore = totalAssetsUSDC();
        if (usdcAmount == 0 || navBefore == 0) return 0;

        uint256 remaining = usdcAmount;
        uint256 idleUsdc = usdc.balanceOf(address(this));
        if (idleUsdc > 0) {
            uint256 idleReturned = idleUsdc > remaining ? remaining : idleUsdc;
            remaining -= idleReturned;
            usdcReturned += idleReturned;
            usdc.safeTransfer(vault, idleReturned);
        }
        if (remaining == 0) {
            emit Withdrawn(usdcAmount, usdcReturned);
            return usdcReturned;
        }

        uint256 assetNav = navBefore > idleUsdc ? navBefore - idleUsdc : 0;
        if (assetNav == 0) {
            emit Withdrawn(usdcAmount, usdcReturned);
            return usdcReturned;
        }

        uint256 count = _assets.length;
        uint256 balanceBefore = usdc.balanceOf(address(this));
        for (uint256 i; i < count; ++i) {
            IERC20 token = IERC20(_assets[i].token);
            uint256 balance = token.balanceOf(address(this));
            uint256 sellAmount = remaining >= assetNav ? balance : Math.mulDiv(balance, remaining, assetNav);
            if (sellAmount == 0) continue;
            _swap(_sellPaths[i], sellAmount, address(this));
        }

        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 swapReturned = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (swapReturned > remaining) swapReturned = remaining;
        usdcReturned += swapReturned;
        usdc.safeTransfer(vault, swapReturned);

        emit Withdrawn(usdcAmount, usdcReturned);
    }

    /// @notice Return any idle USDC rewards to the vault as realised yield.
    function harvest() external onlyVault returns (uint256 yieldUsdc) {
        yieldUsdc = usdc.balanceOf(address(this));
        if (yieldUsdc > 0) {
            usdc.safeTransfer(vault, yieldUsdc);
        }
        emit Harvested(yieldUsdc);
    }

    /// @notice Rebalance the configured basket back toward approved Sleeve A weights.
    /// @dev Intended for the monthly 15th rebalance job. This only trades inside
    ///      Sleeve A and never moves funds to Sleeve C.
    function rebalance() external onlyOwner {
        uint256 count = _assets.length;
        if (count == 0) revert InvalidAssetCount();

        uint256 navBefore = totalAssetsUSDC();
        if (navBefore == 0) return;

        for (uint256 i; i < count; ++i) {
            uint256 currentValue = _assetValueUSDC(i);
            uint256 targetValue = Math.mulDiv(navBefore, _assets[i].weightBps, BPS_DENOM);
            if (currentValue <= targetValue) continue;

            uint256 excessValue = currentValue - targetValue;
            uint256 balance = IERC20(_assets[i].token).balanceOf(address(this));
            uint256 sellAmount = Math.mulDiv(balance, excessValue, currentValue);
            if (sellAmount == 0) continue;
            _swap(_sellPaths[i], sellAmount, address(this));
        }

        uint256 navAfterSells = totalAssetsUSDC();
        uint256 idleUsdc = usdc.balanceOf(address(this));
        for (uint256 i; i < count && idleUsdc > 0; ++i) {
            uint256 currentValue = _assetValueUSDC(i);
            uint256 targetValue = Math.mulDiv(navAfterSells, _assets[i].weightBps, BPS_DENOM);
            if (currentValue >= targetValue) continue;

            uint256 buyAmount = targetValue - currentValue;
            if (buyAmount > idleUsdc) buyAmount = idleUsdc;
            if (buyAmount == 0) continue;
            _swap(_buyPaths[i], buyAmount, address(this));
            idleUsdc = usdc.balanceOf(address(this));
        }

        emit Rebalanced(totalAssetsUSDC());
    }

    /// @notice Sell one configured asset to USDC without relying on oracle value.
    function emergencyUnwindAsset(uint256 index, uint256 tokenAmount) external onlyOwner {
        if (index >= _assets.length) revert InvalidAssetCount();

        uint256 balance = IERC20(_assets[index].token).balanceOf(address(this));
        uint256 sellAmount = tokenAmount > balance ? balance : tokenAmount;
        if (sellAmount == 0) return;

        _swap(_sellPaths[index], sellAmount, address(this));
        emit EmergencyUnwound(index, sellAmount);
    }

    /// @notice Sell all configured assets to USDC without relying on oracle values.
    function emergencyUnwindAll() external onlyOwnerOrVault {
        uint256 count = _assets.length;
        for (uint256 i; i < count; ++i) {
            uint256 balance = IERC20(_assets[i].token).balanceOf(address(this));
            if (balance == 0) continue;
            _swap(_sellPaths[i], balance, address(this));
            emit EmergencyUnwound(i, balance);
        }
        emit EmergencyUnwoundAll();
    }

    function totalAssetsUSDC() public view returns (uint256 totalUsdc) {
        totalUsdc = usdc.balanceOf(address(this));

        uint256 count = _assets.length;
        for (uint256 i; i < count; ++i) {
            totalUsdc += _assetValueUSDC(i);
        }
    }

    function _assetValueUSDC(uint256 index) internal view returns (uint256) {
        AssetConfig memory asset = _assets[index];
        uint256 balance = IERC20(asset.token).balanceOf(address(this));
        if (balance == 0) return 0;

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(asset.priceFeed).latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(asset.priceFeed);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp > updatedAt + asset.maxStale) {
            revert StalePrice(asset.priceFeed);
        }

        uint8 feedDecimals = IChainlinkAggregator(asset.priceFeed).decimals();
        uint256 numerator = Math.mulDiv(balance, uint256(answer), 10 ** asset.tokenDecimals);
        return Math.mulDiv(numerator, 10 ** USDC_DECIMALS, 10 ** feedDecimals);
    }

    function _swap(address[] storage storedPath, uint256 amountIn, address to) internal {
        address[] memory path = storedPath;

        IERC20(path[0]).forceApprove(address(router), amountIn);

        uint256[] memory quote = router.getAmountsOut(amountIn, path);
        uint256 minOut = Math.mulDiv(quote[quote.length - 1], BPS_DENOM - maxSlippageBps, BPS_DENOM);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minOut, path, to, address(0), block.timestamp
        );
    }

    function _validatePaths(address token, address[] calldata buyPath, address[] calldata sellPath) internal view {
        if (
            buyPath.length < 2 || sellPath.length < 2 || buyPath[0] != address(usdc)
                || buyPath[buyPath.length - 1] != token || sellPath[0] != token
                || sellPath[sellPath.length - 1] != address(usdc)
        ) {
            revert InvalidSwapPath();
        }

        for (uint256 i; i < buyPath.length; ++i) {
            if (buyPath[i] == address(0)) revert ZeroAddress();
        }
        for (uint256 i; i < sellPath.length; ++i) {
            if (sellPath[i] == address(0)) revert ZeroAddress();
        }
    }

    function _validatePathsMemory(address token, address[] memory buyPath, address[] memory sellPath) internal view {
        if (
            buyPath.length < 2 || sellPath.length < 2 || buyPath[0] != address(usdc)
                || buyPath[buyPath.length - 1] != token || sellPath[0] != token
                || sellPath[sellPath.length - 1] != address(usdc)
        ) {
            revert InvalidSwapPath();
        }

        for (uint256 i; i < buyPath.length; ++i) {
            if (buyPath[i] == address(0)) revert ZeroAddress();
        }
        for (uint256 i; i < sellPath.length; ++i) {
            if (sellPath[i] == address(0)) revert ZeroAddress();
        }
    }

    function _copyPath(address[] storage destination, address[] calldata source) internal {
        for (uint256 i; i < source.length; ++i) {
            destination.push(source[i]);
        }
    }

    function _copyPathMemory(address[] storage destination, address[] memory source) internal {
        for (uint256 i; i < source.length; ++i) {
            destination.push(source[i]);
        }
    }

    function _validatePrice(address feed, uint32 maxStale) internal view {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(feed);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp > updatedAt + maxStale) {
            revert StalePrice(feed);
        }
    }

    function _adapterHasValue() internal view returns (bool) {
        if (usdc.balanceOf(address(this)) > 0) return true;

        uint256 count = _assets.length;
        for (uint256 i; i < count; ++i) {
            if (IERC20(_assets[i].token).balanceOf(address(this)) > 0) return true;
        }

        return false;
    }
}
