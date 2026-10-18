// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BookTypes} from './BookTypes.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice Pure pricing, escrow and commitment helpers with explicit integer rounding.
library BookMath {
  function pow10(uint8 exponent) internal pure returns (uint256 scale) {
    scale = 1;
    for (uint256 i; i < exponent; ++i) {
      scale *= 10;
    }
  }

  /// @dev floor(xUsd * 10^usdtDecimals * 1e18 / (usdtUsd * 10^xDecimals)).
  function referencePriceFromFeeds(
    uint256 xUsd,
    uint8 xDecimals,
    uint256 usdtUsd,
    uint8 usdtDecimals
  ) internal pure returns (uint256) {
    return Math.mulDiv(xUsd, BookTypes.PRICE_SCALE * pow10(usdtDecimals), usdtUsd * pow10(xDecimals));
  }

  /// @dev p* = tick * ceil((kLow + kHigh) / 2). The index is rounded before scaling by `tick`.
  function midpoint(uint256 pLow, uint256 pHigh, uint256 tick) internal pure returns (uint256) {
    return ((pLow / tick + pHigh / tick + 1) / 2) * tick;
  }

  function withinBand(uint256 price, uint256 referencePrice) internal pure returns (bool) {
    uint256 scaled = price * BookTypes.BPS;
    return scaled >= referencePrice * (BookTypes.BPS - BookTypes.BAND_BPS)
      && scaled <= referencePrice * (BookTypes.BPS + BookTypes.BAND_BPS);
  }

  function buyEscrowRequired(uint256 quantity, uint256 limitPrice) internal pure returns (uint256) {
    uint256 cost = Math.mulDiv(quantity, limitPrice, BookTypes.PRICE_SCALE, Math.Rounding.Ceil);
    return cost + Math.mulDiv(cost, BookTypes.FEE_BPS, BookTypes.BPS);
  }

  /// @dev Smallest gross deposit whose post-fee net is exactly `net` (LAUNCH.md section 8).
  function grossForNet(uint256 net, uint256 feeBps) internal pure returns (uint256) {
    if (net == 0) return 0;
    return Math.mulDiv(net - 1, BookTypes.BPS, BookTypes.BPS - feeBps) + 1;
  }

  /// @dev Economic validity in BOOK.md section 3 order. Structural failures are checked by the caller.
  function validity(
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    uint256 escrow,
    uint256 tick,
    uint256 lot
  ) internal pure returns (uint8) {
    if (limitPrice == 0) return BookTypes.INVALID_ZERO_PRICE;
    if (tick == 0 || limitPrice % tick != 0) return BookTypes.INVALID_OFF_TICK;
    if (quantity == 0) return BookTypes.INVALID_ZERO_QTY;
    if (lot == 0 || quantity % lot != 0) return BookTypes.INVALID_OFF_LOT;
    uint256 required = side == BookTypes.SIDE_BUY ? buyEscrowRequired(quantity, limitPrice) : quantity;
    if (escrow < required) return BookTypes.INVALID_ESCROW;
    return BookTypes.VALID;
  }

  function hashOrder(
    uint256 chainId,
    address book,
    uint256 marketId,
    uint256 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    address recipient,
    bytes32 refundsHash,
    uint8 flags,
    bytes32 salt
  ) internal pure returns (bytes32 digest) {
    // abi.encode of these twelve static words is their concatenation. The scratch loop keeps the
    // legacy stack inside its limit; the digest matches keccak256(abi.encode(...)).
    bytes32 tag = BookTypes.BOOK_ORDER_TAG;
    assembly {
      let p := mload(0x40)
      mstore(p, tag)
      mstore(add(p, 0x20), chainId)
      mstore(add(p, 0x40), book)
      mstore(add(p, 0x60), marketId)
      mstore(add(p, 0x80), epochId)
      mstore(add(p, 0xa0), side)
      mstore(add(p, 0xc0), limitPrice)
      mstore(add(p, 0xe0), quantity)
      mstore(add(p, 0x100), recipient)
      mstore(add(p, 0x120), refundsHash)
      mstore(add(p, 0x140), flags)
      mstore(add(p, 0x160), salt)
      digest := keccak256(p, 0x180)
    }
  }

  function fillOf(
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    uint256 prefix,
    BookTypes.EpochState memory epoch
  ) internal pure returns (uint256) {
    if (epoch.status != BookTypes.EPOCH_CLEARED) return 0;
    if (side == BookTypes.SIDE_BUY) {
      if (limitPrice < epoch.price) return 0;
    } else if (limitPrice > epoch.price) {
      return 0;
    }
    if (epoch.longSide == BookTypes.LONG_NONE || !_isLong(side, epoch.longSide)) return quantity;
    if (side == BookTypes.SIDE_BUY) {
      if (limitPrice > epoch.marginalLevel) return quantity;
      if (limitPrice != epoch.marginalLevel) return 0;
    } else {
      if (limitPrice < epoch.marginalLevel) return quantity;
      if (limitPrice != epoch.marginalLevel) return 0;
    }
    return Math.mulDiv(prefix + quantity, epoch.marginalRemaining, epoch.marginalTotal)
      - Math.mulDiv(prefix, epoch.marginalRemaining, epoch.marginalTotal);
  }

  /// @dev `LONG_*` and `SIDE_*` are different enums. Compare the roles, not the raw codes.
  function _isLong(uint8 side, uint8 longSide) private pure returns (bool) {
    return (side == BookTypes.SIDE_BUY && longSide == BookTypes.LONG_BUY)
      || (side == BookTypes.SIDE_SELL && longSide == BookTypes.LONG_SELL);
  }

  function payment(
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    uint256 prefix,
    uint256 escrow,
    uint8 validityCode,
    BookTypes.EpochState memory epoch
  ) internal pure returns (BookTypes.Payment memory p) {
    if (epoch.status != BookTypes.EPOCH_CLEARED || validityCode != BookTypes.VALID) {
      if (side == BookTypes.SIDE_BUY) p.quoteRefund = escrow;
      else p.baseRefund = escrow;
      return p;
    }
    p.fill = fillOf(side, limitPrice, quantity, prefix, epoch);
    if (side == BookTypes.SIDE_BUY) {
      p.quoteAmount = Math.mulDiv(p.fill, epoch.price, BookTypes.PRICE_SCALE, Math.Rounding.Ceil);
      p.fee = Math.mulDiv(p.quoteAmount, BookTypes.FEE_BPS, BookTypes.BPS);
      p.baseOut = p.fill;
      p.quoteRefund = escrow - p.quoteAmount - p.fee;
    } else {
      p.quoteAmount = Math.mulDiv(p.fill, epoch.price, BookTypes.PRICE_SCALE);
      p.fee = Math.mulDiv(p.quoteAmount, BookTypes.FEE_BPS, BookTypes.BPS);
      p.quoteOut = p.quoteAmount - p.fee;
      p.baseRefund = escrow - p.fill;
    }
  }
}
