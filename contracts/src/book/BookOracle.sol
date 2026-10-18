// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BookMath} from './BookMath.sol';
import {BookTypes} from './BookTypes.sol';
import {IChainlinkFeed, IPancakeV3OraclePool} from './interfaces/IBookOracles.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice Reference price: Chainlink X/USD and USDT/USD, or a PancakeSwap V3 30-minute TWAP.
/// @dev Tick conversion is an independent Q128.128 binary exponentiation of 1.0001. The factors are
///      round-half-up values of 2^128 / 1.0001^(2^(i-1)) (bit 0 uses sqrt(1.0001)), computed in-repo.
///      Uniswap v3-core TickMath is GPL-2.0-or-later and is not vendored.
library BookOracle {
  int24 internal constant MAX_TICK = 887_272;

  error TickOutOfRange();
  error StaleOracle();
  error BadOracle();

  /// @notice Linked entry point (see BookClearing): keeps the oracle code out of SealedBook's runtime.
  function readReferenceLinked(BookTypes.Market memory market, address quote) public view returns (uint256) {
    return readReference(market, quote);
  }

  function readReference(BookTypes.Market memory market, address quote) internal view returns (uint256 price) {
    if (market.oracleKind == BookTypes.ORACLE_CHAINLINK) {
      uint256 xUsd = _readFeed(market.baseFeed, market.baseHeartbeat);
      uint256 usdtUsd = _readFeed(market.quoteFeed, market.quoteHeartbeat);
      price = BookMath.referencePriceFromFeeds(xUsd, market.baseDecimals, usdtUsd, market.quoteDecimals);
    } else {
      price = _twap(market.baseFeed, market.base, quote);
    }
    if (price == 0 || price > BookTypes.MAX_UINT128) revert BadOracle();
  }

  function _readFeed(address feed, uint32 heartbeat) private view returns (uint256) {
    (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = IChainlinkFeed(feed).latestRoundData();
    if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId || updatedAt > block.timestamp) revert BadOracle();
    if (block.timestamp - updatedAt > heartbeat) revert StaleOracle();
    return uint256(answer);
  }

  /// @dev Arithmetic-mean tick over the last 30 minutes, then quote wei per `1e18` base wei.
  function _twap(address pool, address base, address quote) private view returns (uint256) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = uint32(BookTypes.TWAP_WINDOW);
    secondsAgos[1] = 0;
    (int56[] memory cumulatives,) = IPancakeV3OraclePool(pool).observe(secondsAgos);
    int56 delta = cumulatives[1] - cumulatives[0];
    int56 window = int56(uint56(BookTypes.TWAP_WINDOW));
    int24 tick = int24(delta / window);
    if (delta < 0 && delta % window != 0) tick--;
    return quoteAtTick(tick, BookTypes.PRICE_SCALE, base < quote);
  }

  /// @notice Quote-asset wei for `baseAmount` wei of base at `tick` (token1 per token0 = 1.0001^tick).
  function quoteAtTick(int24 tick, uint256 baseAmount, bool baseIsToken0) internal pure returns (uint256) {
    uint160 sqrtPriceX96 = sqrtRatioAtTick(tick);
    if (sqrtPriceX96 <= type(uint128).max) {
      uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
      if (ratioX192 == 0) revert BadOracle();
      return baseIsToken0 ? Math.mulDiv(ratioX192, baseAmount, 1 << 192) : Math.mulDiv(1 << 192, baseAmount, ratioX192);
    }
    uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    if (ratioX128 == 0) revert BadOracle();
    return baseIsToken0 ? Math.mulDiv(ratioX128, baseAmount, 1 << 128) : Math.mulDiv(1 << 128, baseAmount, ratioX128);
  }

  /// @dev sqrt(1.0001^tick) as a Q64.96. Reverts outside the V3 tick domain.
  function sqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
    uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
    if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange();
    uint256 ratio = 1 << 128;
    uint256[20] memory factors = _factors();
    for (uint256 i; i < 20; ++i) {
      if ((absTick & (uint256(1) << i)) != 0) ratio = (ratio * factors[i]) >> 128;
    }
    if (tick > 0) ratio = type(uint256).max / ratio;
    sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
  }

  function _factors() private pure returns (uint256[20] memory f) {
    f[0] = 0xfffcb933bd6fad37aa2d162d1a594001;
    f[1] = 0xfff97272373d413259a46990580e213a;
    f[2] = 0xfff2e50f5f656932ef12357cf3c7fdcc;
    f[3] = 0xffe5caca7e10e4e61c3624eaa0941cd0;
    f[4] = 0xffcb9843d60f6159c9db58835c926644;
    f[5] = 0xff973b41fa98c081472e6896dfb254c0;
    f[6] = 0xff2ea16466c96a3843ec78b326b52861;
    f[7] = 0xfe5dee046a99a2a811c461f1969c3053;
    f[8] = 0xfcbe86c7900a88aedcffc83b479aa3a4;
    f[9] = 0xf987a7253ac413176f2b074cf7815e54;
    f[10] = 0xf3392b0822b70005940c7a398e4b70f3;
    f[11] = 0xe7159475a2c29b7443b29c7fa6e889d9;
    f[12] = 0xd097f3bdfd2022b8845ad8f792aa5825;
    f[13] = 0xa9f746462d870fdf8a65dc1f90e061e5;
    f[14] = 0x70d869a156d2a1b890bb3df62baf32f7;
    f[15] = 0x31be135f97d08fd981231505542fcfa6;
    f[16] = 0x9aa508b5b7a84e1c677de54f3e99bc9;
    f[17] = 0x5d6af8dedb81196699c329225ee604;
    f[18] = 0x2216e584f5fa1ea926041bedfe98;
    f[19] = 0x48a170391f7dc42444e8fa2;
  }
}
