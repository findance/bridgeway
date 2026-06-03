// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "../../contracts/adapters/SleeveADualMorphoEthWrapper.sol";
import "../../contracts/core/ClearcrestAdmin.sol";
import "../../contracts/core/ClearcrestVault.sol";

/// @title 15_DeployAndWireSleeveAEthMorpho
/// @notice Deploys the Sleeve A ETH route and atomically rewires Sleeve A to
///         60% existing cbBTC route / 40% ETH Morpho route.
///
/// Required env vars:
///   DEPLOYER, VAULT, VAULT_OWNER, SLEEVE_A_WRAPPER
///   USDC, WETH, ETH_USD_PRICE_FEED, AERODROME_SWAP_ROUTER
///   MORPHO_ETH_VAULT_A, MORPHO_ETH_VAULT_B
///
/// Required swap config:
///   ETH_SWAP_TICK_SPACING (must be confirmed from the USDC/WETH Slipstream pool)
///
/// Optional:
///   ADMIN, MAX_STALE_SECONDS
contract DeployAndWireSleeveAEthMorpho is Script {
    struct Cfg {
        address vault;
        address admin;
        address vaultOwner;
        address sleeveACbbtcWrapper;
        address usdc;
        address weth;
        address ethUsdFeed;
        address swapRouter;
        address morphoVaultA;
        address morphoVaultB;
        int24 tickSpacing;
        uint256 maxStale;
    }

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        Cfg memory c = _load();
        _validateConfig(c);

        vm.startBroadcast(deployer);

        SleeveADualMorphoEthWrapper ethAdapter = new SleeveADualMorphoEthWrapper(
            c.vault,
            deployer,
            c.usdc,
            c.weth,
            c.swapRouter,
            c.ethUsdFeed,
            c.morphoVaultA,
            c.morphoVaultB,
            c.tickSpacing,
            c.maxStale
        );
        console.log("SleeveADualMorphoEthWrapper:", address(ethAdapter));
        console.log("ETH adapter internal split: 6000 / 4000");

        _wireVault(c, address(ethAdapter));

        if (c.vaultOwner != deployer) {
            ethAdapter.transferOwnership(c.vaultOwner);
            console.log("Ownership transfer initiated to:", c.vaultOwner);
        }

        vm.stopBroadcast();

        console.log("\n=== Save this ===");
        console.log("SLEEVE_A_ETH_MORPHO_ADAPTER=", address(ethAdapter));
        console.log("Sleeve A routes now target: cbBTC 6000 bps / ETH Morpho 4000 bps");
    }

    function _wireVault(Cfg memory c, address ethAdapter) internal {
        address[] memory sleeveARoutes = new address[](2);
        sleeveARoutes[0] = c.sleeveACbbtcWrapper;
        sleeveARoutes[1] = ethAdapter;

        uint16[] memory sleeveABps = new uint16[](2);
        sleeveABps[0] = 6_000;
        sleeveABps[1] = 4_000;

        bool[] memory sleeveAActive = new bool[](2);
        sleeveAActive[0] = true;
        sleeveAActive[1] = true;

        if (c.admin == address(0)) {
            ClearcrestVault vault = ClearcrestVault(c.vault);
            vault.setTrustedSleeveAdapter(c.sleeveACbbtcWrapper, true);
            vault.setTrustedSleeveAdapter(ethAdapter, true);
            vault.configureSleeveAdapterRoutes(0, sleeveARoutes, sleeveABps, sleeveAActive);
            vault.setTrustedSleeveAsset(0, c.weth, true);
        } else {
            ClearcrestAdmin.Call[] memory calls = new ClearcrestAdmin.Call[](4);
            calls[0] = ClearcrestAdmin.Call({
                target: c.vault,
                data: abi.encodeCall(ClearcrestVault.setTrustedSleeveAdapter, (c.sleeveACbbtcWrapper, true))
            });
            calls[1] = ClearcrestAdmin.Call({
                target: c.vault, data: abi.encodeCall(ClearcrestVault.setTrustedSleeveAdapter, (ethAdapter, true))
            });
            calls[2] = ClearcrestAdmin.Call({
                target: c.vault,
                data: abi.encodeCall(
                    ClearcrestVault.configureSleeveAdapterRoutes, (0, sleeveARoutes, sleeveABps, sleeveAActive)
                )
            });
            calls[3] = ClearcrestAdmin.Call({
                target: c.vault, data: abi.encodeCall(ClearcrestVault.setTrustedSleeveAsset, (0, c.weth, true))
            });
            ClearcrestAdmin(c.admin).executeBootstrapOperation(calls);
        }

        console.log("Sleeve A route 0 cbBTC:", c.sleeveACbbtcWrapper);
        console.log("Sleeve A route 1 ETH Morpho:", ethAdapter);
        console.log("Sleeve A route bps: 6000 / 4000");
        console.log("WETH trusted/protected for Sleeve A:", c.weth);
    }

    function _load() internal view returns (Cfg memory c) {
        c.vault = vm.envAddress("VAULT");
        c.admin = vm.envOr("ADMIN", address(0));
        c.vaultOwner = vm.envAddress("VAULT_OWNER");
        c.sleeveACbbtcWrapper = vm.envAddress("SLEEVE_A_WRAPPER");
        c.usdc = vm.envAddress("USDC");
        c.weth = vm.envAddress("WETH");
        c.ethUsdFeed = vm.envAddress("ETH_USD_PRICE_FEED");
        c.swapRouter = vm.envAddress("AERODROME_SWAP_ROUTER");
        c.morphoVaultA = vm.envAddress("MORPHO_ETH_VAULT_A");
        c.morphoVaultB = vm.envAddress("MORPHO_ETH_VAULT_B");
        c.tickSpacing = int24(vm.envInt("ETH_SWAP_TICK_SPACING"));
        c.maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));
    }

    function _validateConfig(Cfg memory c) internal view {
        _requireContract(c.vault, "VAULT");
        if (c.admin != address(0)) _requireContract(c.admin, "ADMIN");
        _requireContract(c.sleeveACbbtcWrapper, "SLEEVE_A_WRAPPER");
        _requireContract(c.usdc, "USDC");
        _requireContract(c.weth, "WETH");
        _requireContract(c.ethUsdFeed, "ETH_USD_PRICE_FEED");
        _requireContract(c.swapRouter, "AERODROME_SWAP_ROUTER");
        _requireContract(c.morphoVaultA, "MORPHO_ETH_VAULT_A");
        _requireContract(c.morphoVaultB, "MORPHO_ETH_VAULT_B");

        require(IERC4626(c.morphoVaultA).asset() == c.weth, "MORPHO_ETH_VAULT_A_ASSET");
        require(IERC4626(c.morphoVaultB).asset() == c.weth, "MORPHO_ETH_VAULT_B_ASSET");
    }

    function _requireContract(address account, string memory label) internal view {
        require(account.code.length != 0, string.concat(label, "_NOT_CONTRACT"));
    }
}
