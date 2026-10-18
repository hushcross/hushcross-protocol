// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Shared constants and packed layouts for the sealed book (BOOK.md).
library BookTypes {
  uint256 internal constant PRICE_SCALE = 1e18;
  uint256 internal constant BPS = 10_000;
  uint256 internal constant FEE_BPS = 5;
  uint256 internal constant BAND_BPS = 200;
  uint256 internal constant EPOCH_SECONDS = 600;
  uint256 internal constant COMMIT_SECONDS = 480;
  /// @dev After the reveal window, anyone may settle for one more epoch. Then anyone may void.
  uint256 internal constant SETTLE_GRACE = 600;
  uint256 internal constant TWAP_WINDOW = 1800;
  uint256 internal constant MAX_REFUND_NOTES = 16;
  uint256 internal constant MAX_UINT128 = type(uint128).max;
  uint256 internal constant MAX_HEARTBEAT = 1 days;
  /// @dev Bounds the number of orders processed for a market in one epoch.
  uint32 internal constant MAX_ORDERS = 500;
  /// @dev Carry-flagged valid reveals per market and epoch that a band-fail settle carries.
  uint32 internal constant MAX_CARRY = 64;
  /// @dev Default minimum buy escrow at listing (5 USDT, 18 decimals). Sells default to the base equivalent.
  uint128 internal constant DEFAULT_MIN_QUOTE = 5e18;
  uint256 internal constant SNARK_SCALAR_FIELD =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;
  address internal constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  bytes32 internal constant BOOK_ORDER_TAG = keccak256('HushCross.Book.Order.v1');

  uint8 internal constant SIDE_BUY = 0;
  uint8 internal constant SIDE_SELL = 1;

  uint8 internal constant PHASE_COMMIT = 0;
  uint8 internal constant PHASE_REVEAL = 1;
  uint8 internal constant PHASE_SETTLE = 2;
  uint8 internal constant PHASE_EXPIRED = 3;
  uint8 internal constant PHASE_FUTURE = 4;

  uint8 internal constant EPOCH_PENDING = 0;
  uint8 internal constant EPOCH_CLEARED = 1;
  uint8 internal constant EPOCH_VOIDED = 2;

  uint8 internal constant VOID_NO_CROSS = 0;
  uint8 internal constant VOID_BAND = 1;
  uint8 internal constant VOID_NO_REVEALS = 2;
  uint8 internal constant VOID_TIMEOUT = 3;

  uint8 internal constant LONG_NONE = 0;
  uint8 internal constant LONG_BUY = 1;
  uint8 internal constant LONG_SELL = 2;

  uint8 internal constant ORACLE_CHAINLINK = 1;
  uint8 internal constant ORACLE_TWAP = 2;

  uint8 internal constant UNREVEALED = 0;
  uint8 internal constant VALID = 1;
  uint8 internal constant INVALID_ZERO_PRICE = 2;
  uint8 internal constant INVALID_OFF_TICK = 3;
  uint8 internal constant INVALID_ZERO_QTY = 4;
  uint8 internal constant INVALID_OFF_LOT = 5;
  uint8 internal constant INVALID_ESCROW = 6;

  /// @dev Diagnose codes. 0-2 are accepting; the rest revert on settle.
  uint8 internal constant OK_CLEARED = 0;
  uint8 internal constant OK_NO_CROSS = 1;
  uint8 internal constant OK_BAND = 2;
  uint8 internal constant ERR_TICK = 3;
  uint8 internal constant ERR_RANGE = 4;
  uint8 internal constant ERR_ZERO_VOL = 5;
  uint8 internal constant ERR_ENDPOINT = 6;
  uint8 internal constant ERR_LOWER = 7;
  uint8 internal constant ERR_UPPER = 8;
  uint8 internal constant ERR_PIVOT = 9;
  uint8 internal constant ERR_MARGINAL = 10;
  uint8 internal constant ERR_CROSS = 11;
  uint8 internal constant ERR_INVARIANT = 12;

  struct Leaf {
    uint128 limitPrice;
    uint128 quantity;
    uint128 prefix;
    uint128 escrow;
  }

  struct Market {
    address base;
    uint128 tick;
    uint128 lot;
    uint8 oracleKind;
    uint8 baseDecimals;
    uint8 quoteDecimals;
    uint32 baseHeartbeat;
    uint32 quoteHeartbeat;
    address baseFeed;
    address quoteFeed;
    bool listed;
    /// @dev Minimum escrow per commit: USDT for buys, base units for sells.
    uint128 minQuote;
    uint128 minBase;
  }

  struct Order {
    uint128 limitPrice;
    uint128 quantity;
    uint128 escrow;
    uint128 prefix;
    uint64 epoch;
    uint32 marketId;
    uint8 side;
    uint8 flags;
    uint8 validity;
    bool vaultFunded;
    bool claimed;
    address recipient;
    address payer;
    bytes32 refundsHash;
  }

  struct EpochState {
    uint8 status;
    uint8 voidReason;
    uint8 longSide;
    uint64 finalizedAt;
    uint256 price;
    uint256 volume;
    uint256 marginalLevel;
    uint256 marginalRemaining;
    uint256 marginalTotal;
    uint256 quoteVolume;
    uint32 filledOrders;
    uint256 treasuryPaid;
  }

  struct Clearing {
    uint256 price;
    uint256 volume;
    uint256 marginalLevel;
    uint256 marginalRemaining;
    uint256 marginalTotal;
    uint256 buyFees;
    uint256 sellFees;
    uint256 roundingSurplus;
    uint256 quoteVolume;
    uint32 filledOrders;
    uint8 longSide;
  }

  struct Payment {
    uint256 fill;
    uint256 quoteAmount;
    uint256 fee;
    uint256 baseOut;
    uint256 quoteOut;
    uint256 baseRefund;
    uint256 quoteRefund;
  }

  function usdtUnits() internal pure returns (uint256[5] memory u) {
    u[0] = 20e18;
    u[1] = 100e18;
    u[2] = 500e18;
    u[3] = 2000e18;
    u[4] = 10_000e18;
  }

  function bnbUnits() internal pure returns (uint256[5] memory u) {
    u[0] = 0.02e18;
    u[1] = 0.1e18;
    u[2] = 0.5e18;
    u[3] = 2e18;
    u[4] = 10e18;
  }

  function phaseAt(uint64 epoch, uint256 nowTs) internal pure returns (uint8) {
    uint256 start = uint256(epoch) * EPOCH_SECONDS;
    if (nowTs < start) return PHASE_FUTURE;
    uint256 elapsed = nowTs - start;
    if (elapsed < COMMIT_SECONDS) return PHASE_COMMIT;
    if (elapsed < EPOCH_SECONDS) return PHASE_REVEAL;
    if (elapsed < EPOCH_SECONDS + SETTLE_GRACE) return PHASE_SETTLE;
    return PHASE_EXPIRED;
  }
}
