// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../../contracts/interfaces/IChainlinkAggregator.sol";

interface IERC20MetadataProbe {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Probes confirmed Clearcrest token and oracle inputs on the active chain.
/// @dev Run against a live RPC or fork before using any address book for deploys.
contract ProbeMainnetAddresses is Script {
    struct AssetProbe {
        string symbol;
        address token;
        address priceFeed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    function run() external view {
        AssetProbe[] memory probes = _probesForChain(block.chainid);

        for (uint256 i = 0; i < probes.length; ++i) {
            _probeAsset(probes[i]);
        }
    }

    function _probeAsset(AssetProbe memory probe) internal view {
        string memory actualSymbol = IERC20MetadataProbe(probe.token).symbol();
        uint8 actualTokenDecimals = IERC20MetadataProbe(probe.token).decimals();
        require(
            keccak256(bytes(actualSymbol)) == keccak256(bytes(probe.symbol)),
            string.concat("unexpected token symbol for ", probe.symbol)
        );
        require(actualTokenDecimals == probe.tokenDecimals, string.concat("unexpected token decimals for ", probe.symbol));

        IChainlinkAggregator feed = IChainlinkAggregator(probe.priceFeed);
        uint8 actualFeedDecimals = feed.decimals();
        require(actualFeedDecimals == probe.feedDecimals, string.concat("unexpected feed decimals for ", probe.symbol));

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0, string.concat("non-positive price for ", probe.symbol));
        require(updatedAt != 0, string.concat("missing feed update for ", probe.symbol));
    }

    function _probesForChain(uint256 chainId) internal pure returns (AssetProbe[] memory probes) {
        if (chainId == 42161) return _arbitrumProbes();
        if (chainId == 8453) return _baseProbes();
        revert("unsupported chain");
    }

    function _arbitrumProbes() internal pure returns (AssetProbe[] memory probes) {
        probes = new AssetProbe[](4);
        probes[0] = AssetProbe({
            symbol: "USDC",
            token: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            priceFeed: 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3,
            tokenDecimals: 6,
            feedDecimals: 8
        });
        probes[1] = AssetProbe({
            symbol: "WETH",
            token: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            priceFeed: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612,
            tokenDecimals: 18,
            feedDecimals: 8
        });
        probes[2] = AssetProbe({
            symbol: "WBTC",
            token: 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f,
            priceFeed: 0x6ce185860a4963106506C203335A2910413708e9,
            tokenDecimals: 8,
            feedDecimals: 8
        });
        probes[3] = AssetProbe({
            symbol: "LINK",
            token: 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4,
            priceFeed: 0x86E53CF1B870786351Da77A57575e79CB55812CB,
            tokenDecimals: 18,
            feedDecimals: 8
        });
    }

    function _baseProbes() internal pure returns (AssetProbe[] memory probes) {
        probes = new AssetProbe[](4);
        probes[0] = AssetProbe({
            symbol: "USDC",
            token: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            priceFeed: 0x51597f405303C4377E36123cBc172b13269EA163,
            tokenDecimals: 6,
            feedDecimals: 8
        });
        probes[1] = AssetProbe({
            symbol: "WETH",
            token: 0x4200000000000000000000000000000000000006,
            priceFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            tokenDecimals: 18,
            feedDecimals: 8
        });
        probes[2] = AssetProbe({
            symbol: "cbBTC",
            token: 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf,
            priceFeed: 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F,
            tokenDecimals: 8,
            feedDecimals: 8
        });
        probes[3] = AssetProbe({
            symbol: "LINK",
            token: 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196,
            priceFeed: 0x17CAb8FE31E32f08326e5E27412894e49B0f9D65,
            tokenDecimals: 18,
            feedDecimals: 8
        });
    }
}
