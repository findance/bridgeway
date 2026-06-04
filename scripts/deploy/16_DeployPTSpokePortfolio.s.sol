// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestPTSpokePortfolio.sol";
import "../../contracts/core/ClearcrestSleeveCPTSpokePortfolio.sol";

/// @title 16_DeployPTSpokePortfolio
/// @notice Deploys a Pendle PT spoke portfolio on the source chain
///         (Arbitrum preferred for Sleeve C). Hub NAV/CCIP wiring stays
///         explicit because the receiver and hub live on Base.
///
/// Required env vars:
///   DEPLOYER, PT_SPOKE_OWNER, PT_SPOKE_OPERATOR
///   PT_SPOKE_SOURCE_CHAIN_ID, PT_TOKEN, CHAIN_USDC, PENDLE_PT_MARKET
///   PENDLE_PT_ORACLE, ASSET_USD_PRICE_FEED, PENDLE_ROUTER
///
/// Required oracle config:
///   PENDLE_PT_TWAP_SECONDS
///
/// Optional:
///   MAX_STALE_SECONDS, PT_FULFILL_TIMEOUT_SECONDS
///   DEPLOY_SLEEVE_C_PT_SPOKE=true to deploy the Sleeve C-named wrapper
///
/// Backward-compatible env aliases:
///   PT_SUSDE -> PT_TOKEN
///   ETH_USDC or ARBITRUM_USDC -> CHAIN_USDC
///   USDE_USD_PRICE_FEED -> ASSET_USD_PRICE_FEED
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

        bool deploySleeveC = vm.envOr("DEPLOY_SLEEVE_C_PT_SPOKE", false);
        address spokeAddress;
        if (deploySleeveC) {
            spokeAddress = address(
                new ClearcrestSleeveCPTSpokePortfolio(
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
                )
            );
        } else {
            spokeAddress = address(
                new ClearcrestPTSpokePortfolio(
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
                )
            );
        }

        vm.stopBroadcast();

        console.log(deploySleeveC ? "ClearcrestSleeveCPTSpokePortfolio:" : "ClearcrestPTSpokePortfolio:", spokeAddress);
        console.log("PT_SPOKE_PORTFOLIO=", spokeAddress);
        if (deploySleeveC) console.log("Sleeve C PT spoke wrapper enabled");
        console.log("PT:", c.pt);
        console.log("Pendle market:", c.pendleMarket);
        console.log("Source chain id:", c.sourceChainId);
        if (c.sourceChainId == 42161) console.log("Source chain:", "Arbitrum One");
    }

    function _load() internal view returns (Cfg memory c) {
        c.owner = vm.envAddress("PT_SPOKE_OWNER");
        c.operator = vm.envAddress("PT_SPOKE_OPERATOR");
        c.sourceChainId = uint64(vm.envUint("PT_SPOKE_SOURCE_CHAIN_ID"));
        c.pt = _envAddressFallback("PT_TOKEN", "PT_SUSDE", "PT_TOKEN");
        c.usdc = _envAddressWithTwoFallbacks("CHAIN_USDC", "ARBITRUM_USDC", "ETH_USDC", "CHAIN_USDC");
        c.pendleMarket = vm.envAddress("PENDLE_PT_MARKET");
        c.ptOracle = vm.envAddress("PENDLE_PT_ORACLE");
        c.assetUsdFeed = _envAddressFallback("ASSET_USD_PRICE_FEED", "USDE_USD_PRICE_FEED", "ASSET_USD_PRICE_FEED");
        c.pendleRouter = vm.envAddress("PENDLE_ROUTER");
        c.twapDuration = uint32(vm.envUint("PENDLE_PT_TWAP_SECONDS"));
        c.maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));
        c.fulfillTimeout = vm.envOr("PT_FULFILL_TIMEOUT_SECONDS", uint256(1 days));
    }

    function _validateConfig(Cfg memory c) internal view {
        if (c.owner == address(0) || c.operator == address(0)) revert("owner/operator required");
        if (c.sourceChainId == 0) revert("source chain id required");
        if (c.twapDuration == 0) revert("twap required");
        _requireContract(c.pt, "PT_TOKEN");
        _requireContract(c.usdc, "CHAIN_USDC");
        _requireContract(c.pendleMarket, "PENDLE_PT_MARKET");
        _requireContract(c.ptOracle, "PENDLE_PT_ORACLE");
        _requireContract(c.assetUsdFeed, "ASSET_USD_PRICE_FEED");
        _requireContract(c.pendleRouter, "PENDLE_ROUTER");
    }

    function _envAddressFallback(string memory primary, string memory fallback_, string memory label)
        internal
        view
        returns (address value)
    {
        value = vm.envOr(primary, address(0));
        if (value == address(0)) value = vm.envOr(fallback_, address(0));
        if (value == address(0)) revert(string.concat(label, " env var required"));
    }

    function _envAddressWithTwoFallbacks(
        string memory primary,
        string memory fallbackA,
        string memory fallbackB,
        string memory label
    ) internal view returns (address value) {
        value = vm.envOr(primary, address(0));
        if (value == address(0)) value = vm.envOr(fallbackA, address(0));
        if (value == address(0)) value = vm.envOr(fallbackB, address(0));
        if (value == address(0)) revert(string.concat(label, " env var required"));
    }

    function _requireContract(address target, string memory label) internal view {
        if (target == address(0) || target.code.length == 0) revert(string.concat(label, " is not a contract"));
    }
}
