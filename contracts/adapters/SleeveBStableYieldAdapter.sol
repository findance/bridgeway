// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IAaveV3.sol";
import "../interfaces/ISleeveAdapter.sol";

/// @title SleeveBStableYieldAdapter
/// @notice Sleeve B adapter for conservative USDC yield: 70% Aave USDC and
///         30% approved Morpho-style ERC4626 USDC vault.
contract SleeveBStableYieldAdapter is ISleeveAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM = 10_000;
    uint16 public constant AAVE_WEIGHT_BPS = 7_000;
    uint16 public constant MORPHO_WEIGHT_BPS = 3_000;
    uint256 public minMorphoDepositUsdc = 5e6;

    address public immutable vault;
    IERC20 public immutable usdc;
    IERC20 public immutable aUsdc;
    IAaveV3Pool public immutable aavePool;
    IERC4626 public immutable morphoVault;

    event Deployed(uint256 usdcAmount, uint256 aaveAmount, uint256 morphoAmount);
    event Withdrawn(uint256 requestedUsdc, uint256 returnedUsdc);
    event Harvested(uint256 yieldUsdc);
    event Rebalanced(uint256 navAfter);
    event EmergencyWithdrawn(uint256 usdcReturned);
    event MinMorphoDepositUpdated(uint256 minimum);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error OnlyVault();
    error InvalidMorphoAsset();
    error AdapterAssetMismatch(address configured, address real);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @dev L-01: lets `ClearcrestVault.emergencyUnwindSleeves` orchestrate.
    modifier onlyOwnerOrVault() {
        if (msg.sender != owner() && msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _vault, address _owner, address _usdc, address _aavePool, address _aUsdc, address _morphoVault)
        Ownable(_owner)
    {
        if (
            _vault == address(0) || _owner == address(0) || _usdc == address(0) || _aavePool == address(0)
                || _aUsdc == address(0) || _morphoVault == address(0)
        ) {
            revert ZeroAddress();
        }
        if (IERC4626(_morphoVault).asset() != _usdc) revert InvalidMorphoAsset();
        address realAUsdc = IAaveReserveQuery(_aavePool).getReserveData(_usdc).aTokenAddress;
        if (_aUsdc != realAUsdc) revert AdapterAssetMismatch(_aUsdc, realAUsdc);

        vault = _vault;
        usdc = IERC20(_usdc);
        aavePool = IAaveV3Pool(_aavePool);
        aUsdc = IERC20(_aUsdc);
        morphoVault = IERC4626(_morphoVault);
    }

    function deploy(uint256 usdcAmount) external onlyVault nonReentrant {
        uint256 aaveAmount = Math.mulDiv(usdcAmount, AAVE_WEIGHT_BPS, BPS_DENOM);
        uint256 morphoAmount = usdcAmount - aaveAmount;
        if (morphoAmount < minMorphoDepositUsdc) {
            aaveAmount = usdcAmount;
            morphoAmount = 0;
        }

        _supplyAave(aaveAmount);
        _depositMorpho(morphoAmount);

        emit Deployed(usdcAmount, aaveAmount, morphoAmount);
    }

    function setMinMorphoDepositUsdc(uint256 minimum) external onlyOwner {
        minMorphoDepositUsdc = minimum;
        emit MinMorphoDepositUpdated(minimum);
    }

    /// @notice Owner backstop: sweep an arbitrary stuck token to `to`.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function withdraw(uint256 usdcAmount) external onlyVault nonReentrant returns (uint256 usdcReturned) {
        if (usdcAmount == 0) return 0;

        usdcReturned = _useIdle(usdcAmount);
        if (usdcReturned == usdcAmount) {
            usdc.safeTransfer(vault, usdcReturned);
            emit Withdrawn(usdcAmount, usdcReturned);
            return usdcReturned;
        }

        uint256 remaining = usdcAmount - usdcReturned;
        uint256 fromAave = _withdrawAave(remaining);
        usdcReturned += fromAave;
        remaining -= fromAave;

        if (remaining > 0) {
            usdcReturned += _withdrawMorpho(remaining);
        }

        if (usdcReturned > 0) {
            usdc.safeTransfer(vault, usdcReturned);
        }
        emit Withdrawn(usdcAmount, usdcReturned);
    }

    /// @notice Sleeve B yield stays in Sleeve B for compounding. Only idle USDC
    ///         accidentally left in the adapter is returned to the vault.
    function harvest() external onlyVault nonReentrant returns (uint256 yieldUsdc) {
        yieldUsdc = usdc.balanceOf(address(this));
        if (yieldUsdc > 0) {
            usdc.safeTransfer(vault, yieldUsdc);
        }
        emit Harvested(yieldUsdc);
    }

    function totalAssetsUSDC() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + _aaveAssets() + _morphoAssets();
    }

    function rebalance() external onlyOwner nonReentrant {
        uint256 nav = totalAssetsUSDC();
        if (nav == 0) return;

        uint256 targetAave = Math.mulDiv(nav, AAVE_WEIGHT_BPS, BPS_DENOM);
        uint256 currentAave = _aaveAssets();

        if (currentAave > targetAave) {
            _withdrawAave(currentAave - targetAave);
            _depositMorpho(usdc.balanceOf(address(this)));
        } else {
            uint256 morphoExcess = targetAave - currentAave;
            _withdrawMorpho(morphoExcess);
            _supplyAave(usdc.balanceOf(address(this)));
        }

        emit Rebalanced(totalAssetsUSDC());
    }

    function emergencyWithdrawAll() external onlyOwnerOrVault nonReentrant returns (uint256 usdcReturned) {
        _withdrawAave(type(uint256).max);
        _redeemMorphoShares(morphoVault.balanceOf(address(this)));
        usdcReturned = usdc.balanceOf(address(this));
        if (usdcReturned > 0) {
            usdc.safeTransfer(vault, usdcReturned);
        }
        emit EmergencyWithdrawn(usdcReturned);
    }

    function _supplyAave(uint256 amount) internal {
        if (amount == 0) return;
        usdc.forceApprove(address(aavePool), amount);
        aavePool.supply(address(usdc), amount, address(this), 0);
    }

    function _depositMorpho(uint256 amount) internal {
        if (amount == 0) return;
        usdc.forceApprove(address(morphoVault), amount);
        morphoVault.deposit(amount, address(this));
    }

    function _withdrawAave(uint256 amount) internal returns (uint256 withdrawn) {
        uint256 available = _aaveAssets();
        if (available == 0) return 0;
        uint256 request = amount > available ? available : amount;
        uint256 beforeBalance = usdc.balanceOf(address(this));
        aavePool.withdraw(address(usdc), request, address(this));
        withdrawn = usdc.balanceOf(address(this)) - beforeBalance;
    }

    function _withdrawMorpho(uint256 amount) internal returns (uint256 withdrawn) {
        uint256 available = _morphoAssets();
        if (available == 0) return 0;
        uint256 request = amount > available ? available : amount;
        uint256 beforeBalance = usdc.balanceOf(address(this));
        morphoVault.withdraw(request, address(this), address(this));
        withdrawn = usdc.balanceOf(address(this)) - beforeBalance;
    }

    function _redeemMorphoShares(uint256 shares) internal returns (uint256 withdrawn) {
        if (shares == 0) return 0;
        uint256 beforeBalance = usdc.balanceOf(address(this));
        morphoVault.redeem(shares, address(this), address(this));
        withdrawn = usdc.balanceOf(address(this)) - beforeBalance;
    }

    function _useIdle(uint256 amount) internal view returns (uint256 used) {
        uint256 idle = usdc.balanceOf(address(this));
        used = idle > amount ? amount : idle;
    }

    function _aaveAssets() internal view returns (uint256) {
        return aUsdc.balanceOf(address(this));
    }

    function _morphoAssets() internal view returns (uint256) {
        return morphoVault.convertToAssets(morphoVault.balanceOf(address(this)));
    }
}
