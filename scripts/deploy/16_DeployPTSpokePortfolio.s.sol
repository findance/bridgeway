// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestPTSpokePortfolio.sol";

/// @title 16_DeployPTSpokePortfolio
/// @notice Deploys an Ethereum Pendle PT spoke portfolio. Hub NAV/CCIP wiring
///         stays explicit because the receiver and hub live on Base.
///
/// Required env vars:
///   DEPLOYER, PT_SPOKE_OWNER, PT_SPOKE_OPERATOR
///   PT_SPOKE_SOURCE_CHAIN_ID, PT_SUSDE, ETH_USDC, PENDLE_PT_MARKET
///   PENDLE_PT_ORACLE, USDE_USD_PRICE_FEED, PENDLE_ROUTER
///
/// Required oracle config:
///   PENDLE_PT_TWAP_SECONDS
///
/// Optional:
///   MAX_STALE_SECONDS, PT_FULFILL_TIMEOUT_SECONDS
contract DeployPTSpokePortfolio is Script {
    struct Cfg {
        address owner;
        address operator;
        uint64 sourceChainId;
        address pt;
        address usdc;
        address pendleMarket;
        address ptOracle;
        address assetUsdFeed;
        address pendleRouter;
        uint32 twapDuration;
        uint256 maxStale;
        uint256 fulfillTimeout;
    }

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        Cfg memory c = _load();
        _validateConfig(c);

        vm.startBroadcast(deployer);

        ClearcrestPTSpokePortfolio spoke = new ClearcrestPTSpokePortfolio(
            c.owner,
            c.operator,
            c.sourceChainId,
            c.pt,
            c.usdc,
            c.pendleMarket,
            c.ptOracle,
            c.assetUsdFeed,
            c.pendleRouter,
            c.twapDuration,
            c.maxStale,
            c.fulfillTimeout
        );

        vm.stopBroadcast();

        console.log("ClearcrestPTSpokePortfolio:", address(spoke));
        console.log("PT_SPOKE_PORTFOLIO=", address(spoke));
        console.log("PT:", c.pt);
        console.log("Pendle market:", c.pendleMarket);
        console.log("Source chain id:", c.sourceChainId);
    }

    function _load() internal view returns (Cfg memory c) {
        c.owner = vm.envAddress("PT_SPOKE_OWNER");
        c.operator = vm.envAddress("PT_SPOKE_OPERATOR");
        c.sourceChainId = uint64(vm.envUint("PT_SPOKE_SOURCE_CHAIN_ID"));
        c.pt = vm.envAddress("PT_SUSDE");
        c.usdc = vm.envAddress("ETH_USDC");
        c.pendleMarket = vm.envAddress("PENDLE_PT_MARKET");
        c.ptOracle = vm.envAddress("PENDLE_PT_ORACLE");
        c.assetUsdFeed = vm.envAddress("USDE_USD_PRICE_FEED");
        c.pendleRouter = vm.envAddress("PENDLE_ROUTER");
        c.twapDuration = uint32(vm.envUint("PENDLE_PT_TWAP_SECONDS"));
        c.maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));
        c.fulfillTimeout = vm.envOr("PT_FULFILL_TIMEOUT_SECONDS", uint256(1 days));
    }

    function _validateConfig(Cfg memory c) internal view {
        if (c.owner == address(0) || c.operator == address(0)) revert("owner/operator required");
        if (c.sourceChainId == 0) revert("source chain id required");
        if (c.twapDuration == 0) revert("twap required");
        _requireContract(c.pt, "PT_SUSDE");
        _requireContract(c.usdc, "ETH_USDC");
        _requireContract(c.pendleMarket, "PENDLE_PT_MARKET");
        _requireContract(c.ptOracle, "PENDLE_PT_ORACLE");
        _requireContract(c.assetUsdFeed, "USDE_USD_PRICE_FEED");
        _requireContract(c.pendleRouter, "PENDLE_ROUTER");
    }

    function _requireContract(address target, string memory label) internal view {
        if (target == address(0) || target.code.length == 0) revert(string.concat(label, " is not a contract"));
    }
}
