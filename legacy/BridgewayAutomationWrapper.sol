// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ----------------------------------------------------------------
// External interfaces
// ----------------------------------------------------------------

interface IEnzymeVault {
    function getGav() external view returns (uint256);
}

interface ICamelotRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address referrer,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

// Inline interface — avoids Chainlink package import-path fragility across versions.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}

// ================================================================
// BridgewayAutomationWrapper  v10
//
// Sits above an Enzyme Finance vault.  Handles performance fees,
// the 6-way fee split, monthly buyback snapshots, and hourly/daily
// BGW buyback-and-burn via Chainlink Automation.
// ================================================================
contract BridgewayAutomationWrapper is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------
    // Immutables — set once in the implementation constructor
    // ----------------------------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IEnzymeVault          public immutable vault;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC20                public immutable bgwToken;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC20                public immutable usdcToken;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ICamelotRouter        public immutable camelotRouter;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    AggregatorV3Interface public immutable priceFeed;

    // ----------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------
    uint256 public constant PERFORMANCE_FEE_BPS    = 1500;       // 15 %
    uint256 public constant MIN_BUYBACK_USDC        = 10e6;       // $10 USDC (6 dec)
    uint256 public constant OPS_CUT_BPS             = 10;         // 0.1 %
    uint256 public constant SNAPSHOT_INTERVAL       = 30 days;
    uint256 public constant HOURLY_INTERVAL         = 1 hours;
    uint256 public constant DAILY_INTERVAL          = 1 days;
    uint256 public constant DAYS_IN_MONTH           = 30;
    uint256 public constant STALE_PRICE_WINDOW      = 1 hours;
    uint256 public constant FALLBACK_SLIPPAGE_BPS   = 300;        // 3 % hardcoded fallback

    // Upkeep action codes returned by checkUpkeep
    uint8 private constant ACTION_SNAPSHOT = 0;
    uint8 private constant ACTION_HOURLY   = 1;
    uint8 private constant ACTION_DAILY    = 2;

    // ----------------------------------------------------------------
    // Upgradeable storage
    // ----------------------------------------------------------------
    address public teamWallet;
    address public holdbackWallet;
    address public lpSeedWallet;
    address public reserveWallet;

    uint256 public highWaterMark;
    uint256 public estimatedGasCostUSDC;

    uint256 public buybackAccumulator;
    uint256 public dailyBuybackAmount;
    uint256 public hourlyBuybackAmount;

    uint256 public lastSnapshotTime;
    uint256 public lastHourlyTime;
    uint256 public lastDailyTime;

    mapping(address => bool) public blacklisted;

    // ----------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------
    event FeesDistributed(uint256 totalFee);
    event PerformanceFeeCollected(uint256 yieldAmount, uint256 fee);
    event MonthlySnapshotTaken(uint256 accumulator, uint256 daily, uint256 hourly);
    event BuybackExecuted(uint256 usdcSpent, uint256 bgwBurned, bool isHourly);
    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event GasCostUpdated(uint256 newCost);
    event WalletUpdated(string wallet, address newAddress);

    // ----------------------------------------------------------------
    // Constructor — runs once per implementation deploy (sets immutables)
    // ----------------------------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _vault,
        address _bgwToken,
        address _usdcToken,
        address _camelotRouter,
        address _priceFeed
    ) {
        require(_vault         != address(0), "zero vault");
        require(_bgwToken      != address(0), "zero bgw");
        require(_usdcToken     != address(0), "zero usdc");
        require(_camelotRouter != address(0), "zero router");
        require(_priceFeed     != address(0), "zero feed");

        vault         = IEnzymeVault(_vault);
        bgwToken      = IERC20(_bgwToken);
        usdcToken     = IERC20(_usdcToken);
        camelotRouter = ICamelotRouter(_camelotRouter);
        priceFeed     = AggregatorV3Interface(_priceFeed);

        _disableInitializers();
    }

    // ----------------------------------------------------------------
    // Initializer — runs once on proxy deploy
    // ----------------------------------------------------------------
    function initialize(
        address _teamWallet,
        address _holdbackWallet,
        address _lpSeedWallet,
        address _reserveWallet
    ) external initializer {
        require(_teamWallet     != address(0), "zero team");
        require(_holdbackWallet != address(0), "zero holdback");
        require(_lpSeedWallet   != address(0), "zero lp");
        require(_reserveWallet  != address(0), "zero reserve");

        __Ownable_init(msg.sender);
        __Pausable_init();

        teamWallet     = _teamWallet;
        holdbackWallet = _holdbackWallet;
        lpSeedWallet   = _lpSeedWallet;
        reserveWallet  = _reserveWallet;

        highWaterMark        = vault.getGav();
        estimatedGasCostUSDC = 250_000; // $0.25 USDC default
        lastSnapshotTime     = block.timestamp;
    }

    // ================================================================
    // Fee recording
    // Called by owner after Enzyme sweeps accrued staking fees here.
    // yieldAmount is the gross USDC yield; the 15 % performance fee
    // is calculated and split internally.
    // ================================================================
    function recordStakingYield(uint256 yieldAmount) external onlyOwner {
        require(yieldAmount > 0, "zero yield");

        uint256 perfFee = (yieldAmount * PERFORMANCE_FEE_BPS) / 10_000;
        require(usdcToken.balanceOf(address(this)) >= perfFee, "BGW: insufficient USDC");

        _distributeFees(perfFee);
        emit PerformanceFeeCollected(yieldAmount, perfFee);
    }

    function _distributeFees(uint256 totalFee) internal {
        uint256 teamShare     = (totalFee * 45) / 100;
        uint256 holdbackShare = (totalFee * 20) / 100;
        uint256 buybackShare  = (totalFee * 15) / 100;
        uint256 lpShare       = (totalFee * 10) / 100;
        uint256 reserveShare  = (totalFee *  5) / 100;
        // Remainder avoids rounding dust escaping to address(0)
        uint256 burnShare = totalFee - teamShare - holdbackShare - buybackShare - lpShare - reserveShare;

        usdcToken.safeTransfer(teamWallet,     teamShare);
        usdcToken.safeTransfer(holdbackWallet, holdbackShare);
        usdcToken.safeTransfer(lpSeedWallet,   lpShare);
        usdcToken.safeTransfer(reserveWallet,  reserveShare);

        // Burn share: swap and burn immediately if above minimum, else defer to accumulator
        if (burnShare >= MIN_BUYBACK_USDC) {
            _buyAndBurn(burnShare);
        } else {
            buybackAccumulator += burnShare;
        }

        buybackAccumulator += buybackShare;

        emit FeesDistributed(totalFee);
    }

    // ================================================================
    // Chainlink Automation — checkUpkeep
    //
    // Priority order:
    //   0 → monthly snapshot (always takes precedence)
    //   1 → hourly buyback   (if amount >= gas cost)
    //   2 → daily fallback   (if hourly < gas but daily >= gas)
    // ================================================================
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (block.timestamp >= lastSnapshotTime + SNAPSHOT_INTERVAL) {
            return (true, abi.encode(ACTION_SNAPSHOT));
        }

        if (hourlyBuybackAmount > 0 && block.timestamp >= lastHourlyTime + HOURLY_INTERVAL) {
            if (hourlyBuybackAmount >= estimatedGasCostUSDC) {
                return (true, abi.encode(ACTION_HOURLY));
            }
        }

        if (
            dailyBuybackAmount > 0 &&
            dailyBuybackAmount >= estimatedGasCostUSDC &&
            block.timestamp >= lastDailyTime + DAILY_INTERVAL
        ) {
            return (true, abi.encode(ACTION_DAILY));
        }

        return (false, bytes(""));
    }

    // ================================================================
    // Chainlink Automation — performUpkeep
    // ================================================================
    function performUpkeep(bytes calldata performData)
        external
        override
        nonReentrant
        whenNotPaused
    {
        uint8 action = abi.decode(performData, (uint8));

        if (action == ACTION_SNAPSHOT) {
            require(block.timestamp >= lastSnapshotTime + SNAPSHOT_INTERVAL, "snapshot not due");
            _takeMonthlySnapshot();
        } else if (action == ACTION_HOURLY) {
            require(hourlyBuybackAmount > 0, "zero hourly");
            require(hourlyBuybackAmount >= estimatedGasCostUSDC, "hourly below gas");
            require(block.timestamp >= lastHourlyTime + HOURLY_INTERVAL, "hourly not due");
            _executeBuyback(hourlyBuybackAmount, true);
            lastHourlyTime = block.timestamp;
        } else if (action == ACTION_DAILY) {
            require(dailyBuybackAmount > 0, "zero daily");
            require(dailyBuybackAmount >= estimatedGasCostUSDC, "daily below gas");
            require(block.timestamp >= lastDailyTime + DAILY_INTERVAL, "daily not due");
            _executeBuyback(dailyBuybackAmount, false);
            lastDailyTime  = block.timestamp;
            lastHourlyTime = block.timestamp;
        } else {
            revert("unknown action");
        }
    }

    function _takeMonthlySnapshot() internal {
        uint256 acc    = buybackAccumulator;
        uint256 daily  = acc / DAYS_IN_MONTH;
        uint256 hourly = daily / 24;

        dailyBuybackAmount  = daily;
        hourlyBuybackAmount = hourly;
        buybackAccumulator  = 0;
        lastSnapshotTime    = block.timestamp;

        emit MonthlySnapshotTaken(acc, daily, hourly);
    }

    function _executeBuyback(uint256 usdcAmount, bool isHourly) internal {
        require(
            usdcToken.balanceOf(address(this)) >= usdcAmount,
            "BGW: insufficient USDC for buyback"
        );

        uint256 opsCut     = (usdcAmount * OPS_CUT_BPS) / 10_000;
        uint256 swapAmount = usdcAmount - opsCut;

        usdcToken.safeTransfer(holdbackWallet, opsCut);

        _buyAndBurn(swapAmount);
    }

    function _buyAndBurn(uint256 usdcAmount) internal {
        uint256 minBgwOut = _calcMinBgwOut(usdcAmount);

        // Reset-before-set approval pattern
        usdcToken.forceApprove(address(camelotRouter), 0);
        usdcToken.forceApprove(address(camelotRouter), usdcAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdcToken);
        path[1] = address(bgwToken);

        uint256[] memory amounts = camelotRouter.swapExactTokensForTokens(
            usdcAmount,
            minBgwOut,
            path,
            address(this),
            address(0),  // no referrer
            block.timestamp + 300
        );

        uint256 bgwReceived = amounts[amounts.length - 1];
        IBurnable(address(bgwToken)).burn(bgwReceived);

        emit BuybackExecuted(usdcAmount, bgwReceived, false);
    }

    // Compute minimum BGW out using Chainlink price; falls back to 3 % hardcoded slippage.
    function _calcMinBgwOut(uint256 usdcAmount) internal view returns (uint256) {
        try priceFeed.latestRoundData() returns (
            uint80, int256 price, uint256, uint256 updatedAt, uint80
        ) {
            if (price > 0 && block.timestamp - updatedAt <= STALE_PRICE_WINDOW) {
                uint8 feedDecimals = priceFeed.decimals();
                // usdcAmount (6 dec) → BGW (18 dec), price has feedDecimals
                uint256 bgwOut = (usdcAmount * 10 ** (18 - 6) * 10 ** feedDecimals) / uint256(price);
                return (bgwOut * 99) / 100; // 1 % dynamic slippage
            }
        } catch {}

        // Fallback: 3 % hardcoded slippage, assume 1:1 parity (6 dec → 18 dec)
        uint256 bgwBase = usdcAmount * 10 ** (18 - 6);
        return (bgwBase * (10_000 - FALLBACK_SLIPPAGE_BPS)) / 10_000;
    }

    // ================================================================
    // Admin — wallet management
    // ================================================================
    function setTeamWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "zero address");
        teamWallet = _wallet;
        emit WalletUpdated("team", _wallet);
    }

    function setHoldbackWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "zero address");
        holdbackWallet = _wallet;
        emit WalletUpdated("holdback", _wallet);
    }

    function setLpSeedWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "zero address");
        lpSeedWallet = _wallet;
        emit WalletUpdated("lpSeed", _wallet);
    }

    function setReserveWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "zero address");
        reserveWallet = _wallet;
        emit WalletUpdated("reserve", _wallet);
    }

    function setEstimatedGasCost(uint256 _cost) external onlyOwner {
        estimatedGasCostUSDC = _cost;
        emit GasCostUpdated(_cost);
    }

    // ================================================================
    // Admin — AML / emergency controls
    // ================================================================
    function blacklist(address _account) external onlyOwner {
        blacklisted[_account] = true;
        emit Blacklisted(_account);
    }

    function unblacklist(address _account) external onlyOwner {
        blacklisted[_account] = false;
        emit Unblacklisted(_account);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Rescue accidentally sent tokens; USDC and BGW are protected.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(
            token != address(usdcToken) && token != address(bgwToken),
            "cannot rescue core tokens"
        );
        IERC20(token).safeTransfer(to, amount);
    }

    // ================================================================
    // UUPS — only owner may upgrade
    // ================================================================
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
