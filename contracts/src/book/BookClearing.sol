// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BookMath} from './BookMath.sol';
import {BookTypes} from './BookTypes.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice O(n) certificate check for a sealed-book epoch (BOOK.md sections 5-8).
library BookClearing {
  function diagnoseNoCross(
    BookTypes.Leaf[] storage buys,
    BookTypes.Leaf[] storage sells
  ) internal view returns (uint8) {
    uint256 maxBuy;
    uint256 minSell = type(uint256).max;
    bool anyBuy;
    bool anySell;
    uint256 n = buys.length;
    for (uint256 i; i < n; ++i) {
      anyBuy = true;
      uint256 limit = buys[i].limitPrice;
      if (limit > maxBuy) maxBuy = limit;
    }
    n = sells.length;
    for (uint256 i; i < n; ++i) {
      anySell = true;
      uint256 limit = sells[i].limitPrice;
      if (limit < minSell) minSell = limit;
    }
    if (anyBuy && anySell && maxBuy >= minSell) return BookTypes.ERR_CROSS;
    return BookTypes.OK_NO_CROSS;
  }

  struct Depth {
    uint256 belowSupply;
    uint256 lowDemand;
    uint256 lowSupply;
    uint256 highDemand;
    uint256 highSupply;
    uint256 aboveDemand;
    uint256 pivotSupply;
    uint256 pivotDemand;
    uint256 priceDemand;
    uint256 priceSupply;
    uint256 price;
  }

  /// @dev Packed settle hint. One memory pointer keeps the caller's stack inside the legacy 16-slot limit.
  struct Hint {
    uint256 tick;
    uint256 pLow;
    uint256 pHigh;
    uint256 pivot;
    uint256 marginal;
    uint256 ref;
  }

  /// @notice Linked entry points. SealedBook calls the library through these (DELEGATECALL into a
  ///         separately deployed library) so its own runtime stays under the EIP-170 size limit.
  ///         Each one only forwards to the internal function of the same meaning.
  function evaluateLinked(
    BookTypes.Leaf[] storage buys,
    BookTypes.Leaf[] storage sells,
    Hint memory hint
  ) public view returns (uint8 code, BookTypes.Clearing memory clearing) {
    if (!ticksOk(hint.tick, hint.pLow, hint.pHigh, hint.pivot, hint.marginal)) return (BookTypes.ERR_TICK, clearing);
    if (hint.pLow > hint.pHigh) return (BookTypes.ERR_RANGE, clearing);
    Depth memory d = depth(buys, sells, hint.tick, hint.pLow, hint.pHigh, hint.pivot);
    return judge(buys, sells, hint.tick, hint.marginal, hint.ref, d);
  }

  function sideLinked(
    BookTypes.Leaf[] storage orders,
    uint8 which,
    BookTypes.Clearing memory clearing
  ) public view returns (uint256 filled, uint256 notional, uint256 fees, uint32 count) {
    return side(orders, which, clearing);
  }

  function diagnoseNoCrossLinked(
    BookTypes.Leaf[] storage buys,
    BookTypes.Leaf[] storage sells
  ) public view returns (uint8) {
    return diagnoseNoCross(buys, sells);
  }

  function ticksOk(
    uint256 tick,
    uint256 pLow,
    uint256 pHigh,
    uint256 pivot,
    uint256 marginalLevel
  ) internal pure returns (bool) {
    return tick != 0 && pLow != 0 && pHigh != 0 && pivot != 0 && pLow <= BookTypes.MAX_UINT128
      && pHigh <= BookTypes.MAX_UINT128 && pivot <= BookTypes.MAX_UINT128 && marginalLevel <= BookTypes.MAX_UINT128
      && pLow % tick == 0 && pHigh % tick == 0 && pivot % tick == 0 && marginalLevel % tick == 0;
  }

  function depth(
    BookTypes.Leaf[] storage buys,
    BookTypes.Leaf[] storage sells,
    uint256 tick,
    uint256 pLow,
    uint256 pHigh,
    uint256 pivot
  ) internal view returns (Depth memory d) {
    uint256[7] memory px;
    px[0] = pLow - tick;
    px[1] = pLow;
    px[2] = pHigh;
    px[3] = pHigh + tick;
    px[4] = pivot - tick;
    px[5] = pivot;
    px[6] = BookMath.midpoint(pLow, pHigh, tick);
    uint256[7] memory demand;
    uint256[7] memory supply;
    _walk(buys, true, px, demand, supply);
    _walk(sells, false, px, demand, supply);
    d.belowSupply = supply[0];
    d.lowDemand = demand[1];
    d.lowSupply = supply[1];
    d.highDemand = demand[2];
    d.highSupply = supply[2];
    d.aboveDemand = demand[3];
    d.pivotSupply = supply[4];
    d.pivotDemand = demand[5];
    d.priceDemand = demand[6];
    d.priceSupply = supply[6];
    d.price = px[6];
  }

  function judge(
    BookTypes.Leaf[] storage buys,
    BookTypes.Leaf[] storage sells,
    uint256 tick,
    uint256 marginalLevel,
    uint256 oraclePrice,
    Depth memory d
  ) internal view returns (uint8 code, BookTypes.Clearing memory clearing) {
    uint256 best = _min(d.lowDemand, d.lowSupply);
    if (best == 0) return (BookTypes.ERR_ZERO_VOL, clearing);
    if (_min(d.highDemand, d.highSupply) != best) return (BookTypes.ERR_ENDPOINT, clearing);
    if (d.belowSupply >= best) return (BookTypes.ERR_LOWER, clearing);
    if (d.aboveDemand >= best) return (BookTypes.ERR_UPPER, clearing);
    if (d.pivotSupply > best || d.pivotDemand > best) return (BookTypes.ERR_PIVOT, clearing);

    clearing.price = d.price;
    if (!BookMath.withinBand(clearing.price, oraclePrice)) {
      if (marginalLevel != 0) return (BookTypes.ERR_MARGINAL, clearing);
      return (BookTypes.OK_BAND, clearing);
    }
    if (_min(d.priceDemand, d.priceSupply) != best) return (BookTypes.ERR_INVARIANT, clearing);
    clearing.longSide = d.priceDemand > d.priceSupply
      ? BookTypes.LONG_BUY
      : d.priceSupply > d.priceDemand ? BookTypes.LONG_SELL : BookTypes.LONG_NONE;
    (code, clearing.marginalRemaining, clearing.marginalTotal) =
      _marginal(buys, sells, clearing, best, marginalLevel, tick);
    if (code != BookTypes.OK_CLEARED) return (code, clearing);
    clearing.volume = best;
    clearing.marginalLevel = marginalLevel;
    return (BookTypes.OK_CLEARED, clearing);
  }

  function _walk(
    BookTypes.Leaf[] storage orders,
    bool isBuy,
    uint256[7] memory px,
    uint256[7] memory demand,
    uint256[7] memory supply
  ) private view {
    uint256 n = orders.length;
    for (uint256 i; i < n; ++i) {
      uint256 limit = orders[i].limitPrice;
      uint256 qty = orders[i].quantity;
      if (isBuy) _accBuy(limit, qty, px, demand);
      else _accSell(limit, qty, px, supply);
    }
  }

  function _accBuy(uint256 limit, uint256 qty, uint256[7] memory px, uint256[7] memory demand) private pure {
    if (px[0] != 0 && limit >= px[0]) demand[0] += qty;
    if (limit >= px[1]) demand[1] += qty;
    if (limit >= px[2]) demand[2] += qty;
    if (limit >= px[3]) demand[3] += qty;
    if (px[4] != 0 && limit >= px[4]) demand[4] += qty;
    if (limit >= px[5]) demand[5] += qty;
    if (limit >= px[6]) demand[6] += qty;
  }

  function _accSell(uint256 limit, uint256 qty, uint256[7] memory px, uint256[7] memory supply) private pure {
    if (limit <= px[0]) supply[0] += qty;
    if (limit <= px[1]) supply[1] += qty;
    if (limit <= px[2]) supply[2] += qty;
    if (limit <= px[3]) supply[3] += qty;
    if (limit <= px[4]) supply[4] += qty;
    if (limit <= px[5]) supply[5] += qty;
    if (limit <= px[6]) supply[6] += qty;
  }

  function _marginal(
    BookTypes.Leaf[] storage buys,
    BookTypes.Leaf[] storage sells,
    BookTypes.Clearing memory clearing,
    uint256 volume,
    uint256 level,
    uint256 tick
  ) private view returns (uint8, uint256 remaining, uint256 total) {
    uint256 price = clearing.price;
    uint8 longSide = clearing.longSide;
    if (longSide == BookTypes.LONG_NONE) {
      if (level != 0) return (BookTypes.ERR_MARGINAL, 0, 0);
      return (BookTypes.OK_CLEARED, 0, 0);
    }
    if (level == 0 || level % tick != 0) return (BookTypes.ERR_MARGINAL, 0, 0);
    if (longSide == BookTypes.LONG_BUY) {
      if (level < price) return (BookTypes.ERR_MARGINAL, 0, 0);
      uint256 better = _demandAt(buys, level + tick);
      uint256 at = _demandAt(buys, level);
      if (better >= volume || volume > at) return (BookTypes.ERR_MARGINAL, 0, 0);
      return (BookTypes.OK_CLEARED, volume - better, at - better);
    }
    if (level > price || level < tick) return (BookTypes.ERR_MARGINAL, 0, 0);
    uint256 betterSell = _supplyAt(sells, level - tick);
    uint256 atSell = _supplyAt(sells, level);
    if (betterSell >= volume || volume > atSell) return (BookTypes.ERR_MARGINAL, 0, 0);
    return (BookTypes.OK_CLEARED, volume - betterSell, atSell - betterSell);
  }

  function _demandAt(BookTypes.Leaf[] storage buys, uint256 price) private view returns (uint256 demand) {
    if (price == 0) return 0;
    uint256 n = buys.length;
    for (uint256 i; i < n; ++i) {
      if (buys[i].limitPrice >= price) demand += buys[i].quantity;
    }
  }

  function _supplyAt(BookTypes.Leaf[] storage sells, uint256 price) private view returns (uint256 supply) {
    uint256 n = sells.length;
    for (uint256 i; i < n; ++i) {
      if (sells[i].limitPrice <= price) supply += sells[i].quantity;
    }
  }

  /// @dev One side of the fee walk. Callers must give it its own external frame.
  function side(
    BookTypes.Leaf[] storage orders,
    uint8 which,
    BookTypes.Clearing memory clearing
  ) internal view returns (uint256 filled, uint256 notional, uint256 fees, uint32 count) {
    uint256 n = orders.length;
    for (uint256 i; i < n; ++i) {
      uint256 limit = orders[i].limitPrice;
      uint256 qty = orders[i].quantity;
      uint256 prefix = orders[i].prefix;
      uint256 fill = _fill(which, limit, qty, prefix, clearing);
      if (fill > qty) return (type(uint256).max, 0, 0, 0);
      if (fill == 0) continue;
      count += 1;
      filled += fill;
      uint256 escrow = orders[i].escrow;
      if (which == BookTypes.SIDE_BUY) {
        uint256 cost = Math.mulDiv(fill, clearing.price, BookTypes.PRICE_SCALE, Math.Rounding.Ceil);
        uint256 fee = Math.mulDiv(cost, BookTypes.FEE_BPS, BookTypes.BPS);
        if (cost + fee > escrow) return (type(uint256).max, 0, 0, 0);
        notional += cost;
        fees += fee;
      } else {
        if (fill > escrow) return (type(uint256).max, 0, 0, 0);
        uint256 gross = Math.mulDiv(fill, clearing.price, BookTypes.PRICE_SCALE);
        notional += gross;
        fees += Math.mulDiv(gross, BookTypes.FEE_BPS, BookTypes.BPS);
      }
    }
  }

  function _fill(
    uint8 which,
    uint256 limit,
    uint256 qty,
    uint256 prefix,
    BookTypes.Clearing memory clearing
  ) private pure returns (uint256) {
    uint256 price = clearing.price;
    if (which == BookTypes.SIDE_BUY) {
      if (limit < price) return 0;
    } else if (limit > price) {
      return 0;
    }
    uint8 longSide = clearing.longSide;
    bool onLong = (which == BookTypes.SIDE_BUY && longSide == BookTypes.LONG_BUY)
      || (which == BookTypes.SIDE_SELL && longSide == BookTypes.LONG_SELL);
    if (longSide == BookTypes.LONG_NONE || !onLong) return qty;
    uint256 level = clearing.marginalLevel;
    if (which == BookTypes.SIDE_BUY) {
      if (limit > level) return qty;
      if (limit != level) return 0;
    } else {
      if (limit < level) return qty;
      if (limit != level) return 0;
    }
    uint256 remaining = clearing.marginalRemaining;
    uint256 total = clearing.marginalTotal;
    return Math.mulDiv(prefix + qty, remaining, total) - Math.mulDiv(prefix, remaining, total);
  }

  function _min(uint256 a, uint256 b) private pure returns (uint256) {
    return a < b ? a : b;
  }
}
