// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../interfaces/ISleeveAdapter.sol";
import "./FeeLib.sol";

library ClearcrestSleeveGovernance {
    uint8 internal constant SLEEVE_C = 2;

    struct SleeveAdapterRoute {
        address adapter;
        uint16 depositBps;
        bool active;
    }

    struct Layout {
        mapping(uint8 => SleeveAdapterRoute[]) sleeveAdapterRoutes;
        mapping(uint8 => mapping(address => bool)) trustedSleeveAssets;
        mapping(address => uint256) trustedAssetUseCount;
        mapping(address => bool) protectedTokens;
    }

    error InvalidSleeve(uint8 sleeve);
    error RouteLengthMismatch();
    error TooManyRoutes(uint256 count, uint256 max);
    error ZeroAddress();
    error NotContract(address account);
    error DuplicateRoute(address adapter);
    error RouteBpsTooHigh(uint256 totalBps);
    error FundedAdapterRemovalBlocked(uint8 sleeve, address adapter, uint256 assetsUsdc);

    function seedLegacyProtectedTokens(Layout storage self) public {
        self.protectedTokens[0x724dc807b04555b71ed48a6896b6F41593b8C637] = true; // aUSDCn
        self.protectedTokens[0x6ab707Aca953eDAeFBc4fD23bA73294241490620] = true; // aUSDT
        self.protectedTokens[0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8] = true; // aWETH
    }

    function configureSleeveAdapterRoutes(
        Layout storage self,
        uint8 sleeve,
        address[] memory adapters,
        uint16[] memory depositBps,
        bool[] memory active
    ) public returns (uint256 activeBps) {
        activeBps = validateSleeveAdapterRouteConfig(self, sleeve, adapters, depositBps, active);

        delete self.sleeveAdapterRoutes[sleeve];
        for (uint256 i; i < adapters.length; ++i) {
            self.sleeveAdapterRoutes[sleeve].push(
                SleeveAdapterRoute({adapter: adapters[i], depositBps: depositBps[i], active: active[i]})
            );
        }
    }

    function validateSleeveAdapterRouteConfig(
        Layout storage self,
        uint8 sleeve,
        address[] memory adapters,
        uint16[] memory depositBps,
        bool[] memory active
    ) public view returns (uint256 activeBps) {
        validateSleeve(sleeve);
        if (adapters.length != depositBps.length || adapters.length != active.length) revert RouteLengthMismatch();
        if (adapters.length > 10) revert TooManyRoutes(adapters.length, 10);

        for (uint256 i; i < adapters.length; ++i) {
            address adapter = adapters[i];
            if (adapter == address(0)) revert ZeroAddress();
            if (adapter.code.length == 0) revert NotContract(adapter);

            for (uint256 j = i + 1; j < adapters.length; ++j) {
                if (adapter == adapters[j]) revert DuplicateRoute(adapter);
            }

            if (active[i]) activeBps += depositBps[i];
        }
        if (activeBps > FeeLib.BPS_DENOM) revert RouteBpsTooHigh(activeBps);

        SleeveAdapterRoute[] storage existingRoutes = self.sleeveAdapterRoutes[sleeve];
        uint256 existingCount = existingRoutes.length;
        for (uint256 i; i < existingCount; ++i) {
            address existing = existingRoutes[i].adapter;
            if (_containsAdapter(adapters, existing)) continue;

            uint256 existingAssets = ISleeveAdapter(existing).totalAssetsUSDC();
            if (existingAssets > 0) revert FundedAdapterRemovalBlocked(sleeve, existing, existingAssets);
        }
    }

    function routeCount(Layout storage self, uint8 sleeve) public view returns (uint256) {
        validateSleeve(sleeve);
        return self.sleeveAdapterRoutes[sleeve].length;
    }

    function routeAt(Layout storage self, uint8 sleeve, uint256 index)
        public
        view
        returns (address adapter, uint16 depositBps, bool active)
    {
        validateSleeve(sleeve);
        SleeveAdapterRoute memory route = self.sleeveAdapterRoutes[sleeve][index];
        return (route.adapter, route.depositBps, route.active);
    }

    function activeRouteDepositBps(Layout storage self, uint8 sleeve) public view returns (uint256 totalBps) {
        uint256 count = routeCount(self, sleeve);
        for (uint256 i; i < count; ++i) {
            SleeveAdapterRoute memory route = self.sleeveAdapterRoutes[sleeve][i];
            if (route.active) totalBps += route.depositBps;
        }
    }

    function routeAssetsUSDC(Layout storage self, uint8 sleeve) public view returns (uint256 totalUsdc) {
        uint256 count = routeCount(self, sleeve);
        for (uint256 i; i < count; ++i) {
            totalUsdc += ISleeveAdapter(self.sleeveAdapterRoutes[sleeve][i].adapter).totalAssetsUSDC();
        }
    }

    function setTrustedSleeveAsset(Layout storage self, uint8 sleeve, address asset, bool trusted)
        public
        returns (bool changed, bool protectedToken)
    {
        validateSleeve(sleeve);
        if (asset == address(0)) revert ZeroAddress();
        bool current = self.trustedSleeveAssets[sleeve][asset];
        if (current == trusted) return (false, self.protectedTokens[asset]);

        self.trustedSleeveAssets[sleeve][asset] = trusted;
        if (trusted) {
            self.trustedAssetUseCount[asset] += 1;
            self.protectedTokens[asset] = true;
        } else {
            uint256 count = self.trustedAssetUseCount[asset];
            if (count > 0) self.trustedAssetUseCount[asset] = count - 1;
        }

        return (true, self.protectedTokens[asset]);
    }

    function setProtectedToken(Layout storage self, address token, bool protectedToken) public {
        if (token == address(0)) revert ZeroAddress();
        self.protectedTokens[token] = protectedToken;
    }

    function validateSleeve(uint8 sleeve) public pure {
        if (sleeve > SLEEVE_C) revert InvalidSleeve(sleeve);
    }

    function _containsAdapter(address[] memory adapters, address adapter) private pure returns (bool) {
        uint256 count = adapters.length;
        for (uint256 i; i < count; ++i) {
            if (adapters[i] == adapter) return true;
        }
        return false;
    }
}
