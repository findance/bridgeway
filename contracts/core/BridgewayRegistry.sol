// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/IBridgewayRegistry.sol";
import "../interfaces/IChainlinkAggregator.sol";

/// @title BridgewayRegistry
/// @notice Chain-local registry for tokens, price feeds, decimals, and trust
///         status. Deploy one registry per chain and keep adapter logic reusable.
contract BridgewayRegistry is IBridgewayRegistry, Ownable2Step {
    mapping(bytes32 => AssetConfig) private _assets;

    event AssetConfigured(
        bytes32 indexed assetId,
        address indexed token,
        address indexed priceFeed,
        uint8 tokenDecimals,
        uint8 feedDecimals,
        bool trusted
    );
    event AssetTrustUpdated(bytes32 indexed assetId, bool trusted);

    error ZeroAddress();
    error EmptyAssetId();
    error AssetNotConfigured(bytes32 assetId);

    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
    }

    function setAsset(
        bytes32 assetId,
        address token,
        address priceFeed,
        uint8 tokenDecimals,
        uint8 feedDecimals,
        bool trusted
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert EmptyAssetId();
        if (token == address(0) || priceFeed == address(0)) revert ZeroAddress();

        if (tokenDecimals == 0) tokenDecimals = IERC20Metadata(token).decimals();
        if (feedDecimals == 0) feedDecimals = IChainlinkAggregator(priceFeed).decimals();

        _assets[assetId] = AssetConfig({
            token: token,
            priceFeed: priceFeed,
            tokenDecimals: tokenDecimals,
            feedDecimals: feedDecimals,
            trusted: trusted
        });

        emit AssetConfigured(assetId, token, priceFeed, tokenDecimals, feedDecimals, trusted);
    }

    function setTrusted(bytes32 assetId, bool trusted) external onlyOwner {
        AssetConfig storage asset = _assets[assetId];
        if (asset.token == address(0)) revert AssetNotConfigured(assetId);

        asset.trusted = trusted;
        emit AssetTrustUpdated(assetId, trusted);
    }

    function getAsset(bytes32 assetId) external view returns (AssetConfig memory asset) {
        asset = _assets[assetId];
        if (asset.token == address(0)) revert AssetNotConfigured(assetId);
    }
}
