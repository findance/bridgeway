// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title BridgewayChainConfig
/// @notice Canonical chain-local registry seed values for Bridgeway deployments.
library BridgewayChainConfig {
    bytes32 public constant ASSET_USDC = keccak256("USDC");
    bytes32 public constant ASSET_WETH = keccak256("WETH");
    bytes32 public constant ASSET_LINK = keccak256("LINK");

    uint256 public constant ARBITRUM_ONE = 42161;
    uint256 public constant BASE = 8453;

    struct AssetSeed {
        bytes32 assetId;
        address token;
        address priceFeed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool trusted;
    }

    error UnsupportedChain(uint256 chainId);

    function seeds(uint256 chainId) internal pure returns (AssetSeed[] memory result) {
        if (chainId == ARBITRUM_ONE) return arbitrumSeeds();
        if (chainId == BASE) return baseSeeds();
        revert UnsupportedChain(chainId);
    }

    function arbitrumSeeds() internal pure returns (AssetSeed[] memory result) {
        result = new AssetSeed[](3);
        result[0] = AssetSeed({
            assetId: ASSET_USDC,
            token: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            priceFeed: 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3,
            tokenDecimals: 6,
            feedDecimals: 8,
            trusted: true
        });
        result[1] = AssetSeed({
            assetId: ASSET_WETH,
            token: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            priceFeed: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612,
            tokenDecimals: 18,
            feedDecimals: 8,
            trusted: true
        });
        result[2] = AssetSeed({
            assetId: ASSET_LINK,
            token: 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4,
            priceFeed: 0x86E53CF1B870786351Da77A57575e79CB55812CB,
            tokenDecimals: 18,
            feedDecimals: 8,
            trusted: true
        });
    }

    function baseSeeds() internal pure returns (AssetSeed[] memory result) {
        result = new AssetSeed[](3);
        result[0] = AssetSeed({
            assetId: ASSET_USDC,
            token: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            priceFeed: 0x51597f405303C4377E36123cBc172b13269EA163,
            tokenDecimals: 6,
            feedDecimals: 8,
            trusted: true
        });
        result[1] = AssetSeed({
            assetId: ASSET_WETH,
            token: 0x4200000000000000000000000000000000000006,
            priceFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            tokenDecimals: 18,
            feedDecimals: 8,
            trusted: true
        });
        result[2] = AssetSeed({
            assetId: ASSET_LINK,
            token: 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196,
            priceFeed: 0x17CAb8FE31E32f08326e5E27412894e49B0f9D65,
            tokenDecimals: 18,
            feedDecimals: 8,
            trusted: true
        });
    }
}
