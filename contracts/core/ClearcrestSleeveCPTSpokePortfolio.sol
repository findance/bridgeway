// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ClearcrestPTSpokePortfolio.sol";

/// @title ClearcrestSleeveCPTSpokePortfolio
/// @notice Thin named PT spoke for Sleeve C / alpha allocation accounting.
///         Logic intentionally stays in ClearcrestPTSpokePortfolio so hub-spoke
///         settlement and entry guards do not fork into a second code path.
contract ClearcrestSleeveCPTSpokePortfolio is ClearcrestPTSpokePortfolio {
    uint8 public constant SLEEVE_ID = 2;

    constructor(
        address owner_,
        address operator_,
        uint64 sourceChainId_,
        address pt_,
        address usdc_,
        address pendleMarket_,
        address ptOracle_,
        address assetUsdFeed_,
        address pendleRouter_,
        uint32 twapDuration_,
        uint256 maxStale_,
        uint256 fulfillTimeout_
    )
        ClearcrestPTSpokePortfolio(
            owner_,
            operator_,
            sourceChainId_,
            pt_,
            usdc_,
            pendleMarket_,
            ptOracle_,
            assetUsdFeed_,
            pendleRouter_,
            twapDuration_,
            maxStale_,
            fulfillTimeout_
        )
    {}
}
