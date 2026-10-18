// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BookTypes} from './BookTypes.sol';
import {IChainlinkFeed, IPancakeV3OraclePool} from './interfaces/IBookOracles.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice Market listing and minimum-escrow defaults for SealedBook, linked (DELEGATECALL) so SealedBook stays under
///         the EIP-170 size limit. Called directly, the functions only write the library's own unused storage.
library BookListing {
  error InvalidConfig();

  /// @notice Validate and record a Chainlink-referenced market.
  function chainlinkLinked(
    BookTypes.Market storage created,
    address base,
    uint128 tick,
    uint128 lot,
    address baseFeed,
    address quoteFeed,
    uint32 baseHeartbeat,
    uint32 quoteHeartbeat
  ) public {
    if (
      baseHeartbeat == 0 || quoteHeartbeat == 0 || baseHeartbeat > BookTypes.MAX_HEARTBEAT
        || quoteHeartbeat > BookTypes.MAX_HEARTBEAT
    ) revert InvalidConfig();
    if (baseFeed.code.length == 0 || quoteFeed.code.length == 0) revert InvalidConfig();
    uint8 baseDec = IChainlinkFeed(baseFeed).decimals();
    uint8 quoteDec = IChainlinkFeed(quoteFeed).decimals();
    if (baseDec > 18 || quoteDec > 18) revert InvalidConfig();
    created.base = base;
    created.tick = tick;
    created.lot = lot;
    created.oracleKind = BookTypes.ORACLE_CHAINLINK;
    created.baseDecimals = baseDec;
    created.quoteDecimals = quoteDec;
    created.baseHeartbeat = baseHeartbeat;
    created.quoteHeartbeat = quoteHeartbeat;
    created.baseFeed = baseFeed;
    created.quoteFeed = quoteFeed;
    created.listed = true;
  }

  /// @notice Validate and record a PancakeSwap V3 TWAP-referenced market.
  function twapLinked(
    BookTypes.Market storage created,
    address base,
    address quote,
    uint128 tick,
    uint128 lot,
    address pool
  ) public {
    if (pool.code.length == 0) revert InvalidConfig();
    address token0 = IPancakeV3OraclePool(pool).token0();
    address token1 = IPancakeV3OraclePool(pool).token1();
    if (token0 >= token1) revert InvalidConfig();
    bool pairOk = (token0 == base && token1 == quote) || (token1 == base && token0 == quote);
    if (!pairOk) revert InvalidConfig();
    created.base = base;
    created.tick = tick;
    created.lot = lot;
    created.oracleKind = BookTypes.ORACLE_TWAP;
    created.baseFeed = pool;
    created.listed = true;
  }

  /// @notice Listing default: 5 USDT for buys; for sells the base worth 5 USDT at the reference
  ///         price, rounded up to the lot. A reference that cannot be read yet (a fresh TWAP pool) falls back to one
  ///         lot, which the owner should then raise with `setMinEscrow`.
  /// @dev The reference is read through the book's own `referencePrice(uint256)` (`address(this)` is the book).
  function defaultMinEscrowLinked(
    BookTypes.Market storage m,
    uint256 marketId
  ) public returns (uint256 minQuote, uint256 minBase) {
    uint256 lot = m.lot;
    minQuote = BookTypes.DEFAULT_MIN_QUOTE;
    minBase = lot;
    (bool ok, bytes memory ret) =
      address(this).staticcall(abi.encodeWithSignature('referencePrice(uint256)', marketId));
    if (ok && ret.length == 32) {
      uint256 ref = abi.decode(ret, (uint256));
      if (ref != 0) {
        uint256 lots = Math.ceilDiv(minQuote * BookTypes.PRICE_SCALE, ref * lot);
        if (lots * lot > minBase && lots * lot <= BookTypes.MAX_UINT128) minBase = lots * lot;
      }
    }
    m.minQuote = uint128(minQuote);
    m.minBase = uint128(minBase);
  }
}
