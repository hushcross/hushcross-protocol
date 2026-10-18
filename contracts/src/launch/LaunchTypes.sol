// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Shared constants, structs and errors for HushCross Launch.
library LaunchConstants {
  /// @dev Prices are quote base units per 1e18 token base units (both assets use 18 decimals).
  uint256 internal constant PRICE_SCALE = 1e18;
  /// @dev LAUNCH.md section 0: every price, amount, quantity and escrow fits in uint128.
  uint256 internal constant MAX_AMOUNT = type(uint128).max;
  uint256 internal constant BPS = 10_000;
  uint256 internal constant FEE_BPS = 100;
  uint256 internal constant MIN_LIQUIDITY_BPS = 3000;
  uint256 internal constant MAX_LIQUIDITY_BPS = 8000;
  uint256 internal constant MIN_COMMIT_DURATION = 1 hours;
  uint256 internal constant MAX_COMMIT_DURATION = 72 hours;
  uint256 internal constant MIN_REVEAL_DURATION = 1 hours;
  uint256 internal constant MAX_REVEAL_DURATION = 7 days;
  uint256 internal constant MIN_VESTING_DURATION = 90 days;
  uint256 internal constant MAX_VESTING_DURATION = 4 * 365 days;
  /// @dev Bounds the number of bids processed during clearing and finalization.
  uint256 internal constant MAX_BIDS_LIMIT = 1000;
  uint256 internal constant SETTLE_GRACE = 7 days;
  uint256 internal constant MAX_REFUND_NOTES = 16;
  uint256 internal constant SNARK_SCALAR_FIELD =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;
  uint256 internal constant UNIT_COUNT = 5;
  /// @dev Upstream Privacy Pools native asset sentinel.
  address internal constant VAULT_NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
  /// @dev = 0x6b0be99dde7e12273d5da83787239e8862854042870b41c4a0ee4f911e7f0d04 (LAUNCH.md section 2).
  bytes32 internal constant LAUNCH_BID_TAG = keccak256('HushCross.Launch.Bid.v1');
}

/// @notice Creator-supplied sale parameters .
struct LaunchParams {
  string name;
  string symbol;
  address quoteAsset;
  uint256 saleSupply;
  uint256 liquiditySupply;
  uint256 creatorSupply;
  uint256 floorPrice;
  uint256 minRaise;
  uint64 commitDuration;
  uint64 revealDuration;
  uint16 liquidityBps;
  uint64 vestingDuration;
  uint32 maxBids;
}

/// @notice Fully resolved configuration handed to a SealedSale at deployment.
struct SaleConfig {
  uint256 saleId;
  address factory;
  address creator;
  address token;
  address quoteAsset;
  address treasury;
  address entrypoint;
  address wbnb;
  address pancakeFactory;
  address positionManager;
  uint256 saleSupply;
  uint256 lpTokenReserve;
  uint256 floorPrice;
  uint256 minRaise;
  uint256 minEscrow;
  uint64 commitEnd;
  uint64 revealEnd;
  uint16 liquidityBps;
  uint32 maxBids;
  uint256[5] units;
}
