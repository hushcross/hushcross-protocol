// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LaunchConstants} from './LaunchTypes.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice Uniform-price clearing for a sealed sale; see docs/modules/launch.md.
/// @dev Valid bid i demands q_i = floor(maxSpend_i * 1e18 / price_i). With T = sum q, A(p) = sum q (price >= p),
///      B(p) = sum q (price > p): undersubscribed (T < S) => p* = floor and every bid fills; otherwise p* is the
///      unique bid price with A(p*) >= S and B(p*) < S. Marginal bids share R = S - B among M = A - B using the
///      cumulative floor floor((prefix + q) R / M) - floor(prefix R / M) in reveal order; spend rounds up.
library LaunchClearing {
  struct Result {
    uint256 clearingPrice;
    bool undersubscribed;
    uint256 totalDemand;
    uint256 demandAbove;
    uint256 marginalDemand;
    uint256 marginalRemaining;
    uint256 tokensSold;
    uint256 attemptedRaise;
  }

  struct Liquidity {
    uint256 quoteTarget;
    uint256 token;
    uint256 quote;
  }

  error PriceBelowFloor();
  error UndersubscribedPriceMustBeFloor();
  error InsufficientDemandAtPrice();
  error ExcessDemandAbovePrice();

  function pack(uint256 price, uint256 qty) internal pure returns (uint256) {
    return (price << 128) | qty;
  }

  function unpack(uint256 entry) internal pure returns (uint256 price, uint256 qty) {
    price = entry >> 128;
    // forge-lint: disable-next-line(unsafe-typecast)
    qty = uint128(entry);
  }

  function quantity(uint256 maxSpend, uint256 price) internal pure returns (uint256) {
    return Math.mulDiv(maxSpend, LaunchConstants.PRICE_SCALE, price);
  }

  function spend(uint256 fill, uint256 clearingPrice) internal pure returns (uint256) {
    return Math.mulDiv(fill, clearingPrice, LaunchConstants.PRICE_SCALE, Math.Rounding.Ceil);
  }

  /// @notice Tokens allocated to a valid bid (price, q, prefix) under a stored clearing result.
  function fillOf(uint256 price, uint256 qty, uint256 prefix, Result memory r) internal pure returns (uint256) {
    if (r.undersubscribed || price > r.clearingPrice) return qty;
    if (price < r.clearingPrice) return 0;
    return Math.mulDiv(prefix + qty, r.marginalRemaining, r.marginalDemand)
      - Math.mulDiv(prefix, r.marginalRemaining, r.marginalDemand);
  }

  /// @notice O(n) verification of `clearingPrice` (pass 1) plus fills and raise (pass 2), in reveal order.
  function verify(
    uint256[] storage entries,
    uint256 supply,
    uint256 floorPrice,
    uint256 clearingPrice
  ) internal view returns (Result memory r) {
    if (clearingPrice < floorPrice) revert PriceBelowFloor();
    uint256 n = entries.length;
    uint256 total;
    uint256 atOrAbove;
    uint256 above;
    for (uint256 i; i < n; ++i) {
      (uint256 b, uint256 q) = unpack(entries[i]);
      total += q;
      if (b >= clearingPrice) {
        atOrAbove += q;
        if (b > clearingPrice) above += q;
      }
    }
    r.clearingPrice = clearingPrice;
    r.totalDemand = total;
    if (total < supply) {
      if (clearingPrice != floorPrice) revert UndersubscribedPriceMustBeFloor();
      r.undersubscribed = true;
    } else {
      if (atOrAbove < supply) revert InsufficientDemandAtPrice();
      if (above >= supply) revert ExcessDemandAbovePrice();
      r.demandAbove = above;
      r.marginalDemand = atOrAbove - above;
      r.marginalRemaining = supply - above;
    }
    uint256 prefix;
    for (uint256 i; i < n; ++i) {
      (uint256 b, uint256 q) = unpack(entries[i]);
      uint256 fill;
      if (r.undersubscribed || b > clearingPrice) {
        fill = q;
      } else if (b == clearingPrice) {
        fill = fillOf(b, q, prefix, r);
        prefix += q;
      }
      if (fill != 0) {
        r.tokensSold += fill;
        r.attemptedRaise += spend(fill, clearingPrice);
      }
    }
  }

  /// @notice Pool seeding amounts at p* (LAUNCH.md section 7).
  function liquidity(
    uint256 netRaise,
    uint256 liquidityBps,
    uint256 lpTokenReserve,
    uint256 price
  ) internal pure returns (Liquidity memory l) {
    l.quoteTarget = Math.mulDiv(netRaise, liquidityBps, LaunchConstants.BPS);
    uint256 tokensNeeded = Math.mulDiv(l.quoteTarget, LaunchConstants.PRICE_SCALE, price);
    if (tokensNeeded <= lpTokenReserve) {
      (l.token, l.quote) = (tokensNeeded, l.quoteTarget);
    } else {
      (l.token, l.quote) = (lpTokenReserve, Math.mulDiv(lpTokenReserve, price, LaunchConstants.PRICE_SCALE));
    }
    if (l.token == 0 || l.quote == 0) (l.token, l.quote) = (0, 0);
  }

  /// @notice Smallest gross vault deposit whose net after `feeBps` is exactly `net` (LAUNCH.md section 8).
  function grossForNet(uint256 net, uint256 feeBps) internal pure returns (uint256) {
    if (net == 0) return 0;
    return Math.mulDiv(net - 1, LaunchConstants.BPS, LaunchConstants.BPS - feeBps) + 1;
  }
}
