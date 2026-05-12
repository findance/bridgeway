// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Simulates a Chainlink AggregatorV3 price feed.
contract MockPriceFeed {
    int256  private _price;
    uint8   private _decimals;
    bool    private _stale;

    constructor(int256 initialPrice, uint8 dec) {
        _price    = initialPrice;
        _decimals = dec;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId        = 1;
        answer         = _price;
        startedAt      = block.timestamp;
        // If stale, return an updatedAt far in the past so the wrapper falls back
        updatedAt      = _stale ? block.timestamp - 2 hours : block.timestamp;
        answeredInRound = 1;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }

    function setStale() external {
        _stale = true;
    }

    function clearStale() external {
        _stale = false;
    }
}
