// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IBridgewayRegistry {
    struct AssetConfig {
        address token;
        address priceFeed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool trusted;
    }

    function getAsset(bytes32 assetId) external view returns (AssetConfig memory);
}
