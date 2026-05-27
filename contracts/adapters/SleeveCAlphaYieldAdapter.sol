// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/ISleeveAdapter.sol";

/// @title SleeveCAlphaYieldAdapter
/// @notice Capped USDC-denominated alpha sleeve for approved higher-yield
///         strategies such as Ethena/Pendle/Curve wrappers. Each strategy must
///         be an approved ERC4626 vault whose asset is USDC, and no strategy may
///         exceed 50% of Sleeve C policy weight.
contract SleeveCAlphaYieldAdapter is ISleeveAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_STRATEGIES = 6;
    uint16 public constant MAX_STRATEGY_WEIGHT_BPS = 5_000;

    struct StrategyConfig {
        IERC4626 vault;
        uint16 weightBps;
    }

    struct StrategyInput {
        address vault;
        uint16 weightBps;
    }

    address public immutable vault;
    IERC20 public immutable usdc;
    StrategyConfig[] private _strategies;
    uint256 public accountingPrincipal;

    event StrategiesConfigured(uint256 count);
    event Deployed(uint256 usdcAmount);
    event Withdrawn(uint256 requestedUsdc, uint256 returnedUsdc);
    event Harvested(uint256 yieldUsdc);
    event Rebalanced(uint256 navAfter);
    event EmergencyWithdrawn(uint256 usdcReturned);

    error ZeroAddress();
    error OnlyVault();
    error InvalidStrategyCount();
    error InvalidStrategyWeight();
    error InvalidStrategyAsset();
    error DuplicateStrategy();
    error AdapterNotEmpty();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @dev L-01: lets `ClearcrestVault.emergencyUnwindSleeves` orchestrate.
    modifier onlyOwnerOrVault() {
        if (msg.sender != owner() && msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _vault, address _owner, address _usdc) Ownable(_owner) {
        if (_vault == address(0) || _owner == address(0) || _usdc == address(0)) revert ZeroAddress();
        vault = _vault;
        usdc = IERC20(_usdc);
    }

    function strategyCount() external view returns (uint256) {
        return _strategies.length;
    }

    function strategyAt(uint256 index) external view returns (StrategyConfig memory) {
        return _strategies[index];
    }

    function setStrategies(StrategyInput[] calldata newStrategies) external onlyOwner nonReentrant {
        if (_adapterHasValue()) revert AdapterNotEmpty();

        uint256 count = newStrategies.length;
        if (count == 0 || count > MAX_STRATEGIES) revert InvalidStrategyCount();

        uint256 weightTotal;
        for (uint256 i; i < count; ++i) {
            StrategyInput calldata input = newStrategies[i];
            if (input.vault == address(0)) revert ZeroAddress();
            if (input.weightBps == 0 || input.weightBps > MAX_STRATEGY_WEIGHT_BPS) revert InvalidStrategyWeight();
            if (IERC4626(input.vault).asset() != address(usdc)) revert InvalidStrategyAsset();

            for (uint256 j = i + 1; j < count; ++j) {
                if (input.vault == newStrategies[j].vault) revert DuplicateStrategy();
            }
            weightTotal += input.weightBps;
        }

        if (weightTotal != BPS_DENOM) revert InvalidStrategyWeight();

        delete _strategies;
        for (uint256 i; i < count; ++i) {
            _strategies.push(
                StrategyConfig({vault: IERC4626(newStrategies[i].vault), weightBps: newStrategies[i].weightBps})
            );
        }

        emit StrategiesConfigured(count);
    }

    function deploy(uint256 usdcAmount) external onlyVault nonReentrant {
        uint256 count = _strategies.length;
        if (count == 0) revert InvalidStrategyCount();

        accountingPrincipal += usdcAmount;
        uint256 allocated;
        for (uint256 i; i < count; ++i) {
            uint256 amount =
                i == count - 1 ? usdcAmount - allocated : Math.mulDiv(usdcAmount, _strategies[i].weightBps, BPS_DENOM);
            allocated += amount;
            _deposit(_strategies[i].vault, amount);
        }

        emit Deployed(usdcAmount);
    }

    function withdraw(uint256 usdcAmount) external onlyVault nonReentrant returns (uint256 usdcReturned) {
        if (usdcAmount == 0) return 0;

        uint256 nav = totalAssetsUSDC();
        if (nav == 0) return 0;

        uint256 principalReduction = usdcAmount > accountingPrincipal ? accountingPrincipal : usdcAmount;
        accountingPrincipal -= principalReduction;

        usdcReturned = _useIdle(usdcAmount);
        uint256 remaining = usdcAmount - usdcReturned;

        if (remaining > 0) {
            uint256 count = _strategies.length;
            uint256 strategyNav = nav > usdcReturned ? nav - usdcReturned : 0;
            for (uint256 i; i < count; ++i) {
                if (remaining == 0 || strategyNav == 0) break;
                uint256 assets = _strategyAssets(_strategies[i].vault);
                uint256 request = remaining >= strategyNav ? assets : Math.mulDiv(assets, remaining, strategyNav);
                uint256 withdrawn = _withdraw(_strategies[i].vault, request);
                usdcReturned += withdrawn;
                remaining = withdrawn >= remaining ? 0 : remaining - withdrawn;
                strategyNav = strategyNav > assets ? strategyNav - assets : 0;
            }
        }

        uint256 transferAmount = usdcReturned > usdcAmount ? usdcAmount : usdcReturned;
        if (transferAmount > 0) {
            usdc.safeTransfer(vault, transferAmount);
        }
        emit Withdrawn(usdcAmount, transferAmount);
        return transferAmount;
    }

    /// @notice Realise Sleeve C yield as USDC and return it to the vault so
    ///         automation can compound it into Sleeve B instead of back into C.
    function harvest() external onlyVault nonReentrant returns (uint256 yieldUsdc) {
        uint256 nav = totalAssetsUSDC();
        if (nav <= accountingPrincipal) {
            emit Harvested(0);
            return 0;
        }

        uint256 targetYield = nav - accountingPrincipal;
        yieldUsdc = _useIdle(targetYield);
        uint256 remaining = targetYield - yieldUsdc;

        if (remaining > 0) {
            uint256 count = _strategies.length;
            for (uint256 i; i < count; ++i) {
                if (remaining == 0) break;
                uint256 assets = _strategyAssets(_strategies[i].vault);
                uint256 request = remaining > assets ? assets : remaining;
                uint256 withdrawn = _withdraw(_strategies[i].vault, request);
                yieldUsdc += withdrawn;
                remaining = withdrawn >= remaining ? 0 : remaining - withdrawn;
            }
        }

        if (yieldUsdc > targetYield) yieldUsdc = targetYield;
        if (yieldUsdc > 0) {
            usdc.safeTransfer(vault, yieldUsdc);
        }
        emit Harvested(yieldUsdc);
    }

    function totalAssetsUSDC() public view returns (uint256 totalUsdc) {
        totalUsdc = usdc.balanceOf(address(this));
        uint256 count = _strategies.length;
        for (uint256 i; i < count; ++i) {
            totalUsdc += _strategyAssets(_strategies[i].vault);
        }
    }

    function rebalance() external onlyOwner nonReentrant {
        uint256 nav = totalAssetsUSDC();
        if (nav == 0) return;

        uint256 count = _strategies.length;
        for (uint256 i; i < count; ++i) {
            uint256 current = _strategyAssets(_strategies[i].vault);
            uint256 target = Math.mulDiv(nav, _strategies[i].weightBps, BPS_DENOM);
            if (current <= target) continue;
            _withdraw(_strategies[i].vault, current - target);
        }

        uint256 idle = usdc.balanceOf(address(this));
        for (uint256 i; i < count && idle > 0; ++i) {
            uint256 current = _strategyAssets(_strategies[i].vault);
            uint256 target = Math.mulDiv(nav, _strategies[i].weightBps, BPS_DENOM);
            if (current >= target) continue;
            uint256 amount = target - current;
            if (amount > idle) amount = idle;
            _deposit(_strategies[i].vault, amount);
            idle = usdc.balanceOf(address(this));
        }

        emit Rebalanced(totalAssetsUSDC());
    }

    function emergencyWithdrawAll() external onlyOwnerOrVault nonReentrant returns (uint256 usdcReturned) {
        uint256 count = _strategies.length;
        accountingPrincipal = 0;
        for (uint256 i; i < count; ++i) {
            _redeem(_strategies[i].vault, _strategies[i].vault.balanceOf(address(this)));
        }
        usdcReturned = usdc.balanceOf(address(this));
        if (usdcReturned > 0) {
            usdc.safeTransfer(vault, usdcReturned);
        }
        emit EmergencyWithdrawn(usdcReturned);
    }

    function _deposit(IERC4626 strategy, uint256 amount) internal {
        if (amount == 0) return;
        usdc.forceApprove(address(strategy), amount);
        strategy.deposit(amount, address(this));
    }

    function _withdraw(IERC4626 strategy, uint256 amount) internal returns (uint256 withdrawn) {
        if (amount == 0) return 0;
        uint256 available = _strategyAssets(strategy);
        uint256 request = amount > available ? available : amount;
        uint256 beforeBalance = usdc.balanceOf(address(this));
        strategy.withdraw(request, address(this), address(this));
        withdrawn = usdc.balanceOf(address(this)) - beforeBalance;
    }

    function _redeem(IERC4626 strategy, uint256 shares) internal returns (uint256 withdrawn) {
        if (shares == 0) return 0;
        uint256 beforeBalance = usdc.balanceOf(address(this));
        strategy.redeem(shares, address(this), address(this));
        withdrawn = usdc.balanceOf(address(this)) - beforeBalance;
    }

    function _strategyAssets(IERC4626 strategy) internal view returns (uint256) {
        return strategy.convertToAssets(strategy.balanceOf(address(this)));
    }

    function _useIdle(uint256 amount) internal view returns (uint256 used) {
        uint256 idle = usdc.balanceOf(address(this));
        used = idle > amount ? amount : idle;
    }

    function _adapterHasValue() internal view returns (bool) {
        if (usdc.balanceOf(address(this)) > 0) return true;
        uint256 count = _strategies.length;
        for (uint256 i; i < count; ++i) {
            if (_strategies[i].vault.balanceOf(address(this)) > 0) return true;
        }
        return false;
    }
}
