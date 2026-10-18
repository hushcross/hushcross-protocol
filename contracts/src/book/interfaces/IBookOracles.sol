// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Chainlink AggregatorV3 subset used for the reference price.
interface IChainlinkFeed {
  function decimals() external view returns (uint8);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice PancakeSwap V3 pool oracle (Uniswap V3 `observe`). Token order is address-sorted.
interface IPancakeV3OraclePool {
  function token0() external view returns (address);

  function token1() external view returns (address);

  function observe(uint32[] calldata secondsAgos)
    external
    view
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
