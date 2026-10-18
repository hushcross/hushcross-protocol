// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LaunchConstants} from '../LaunchTypes.sol';
import {INonfungiblePositionManager, IPancakeV3Factory, IPancakeV3Pool} from '../interfaces/IPancakeV3.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice Seeds a full-range PancakeSwap V3 position at the clearing price and keeps the NFT forever.
/// @dev Nothing in this contract can transfer the position NFT or remove its liquidity.
///      Trading fees are collected by `SealedSale.collectFees`.
abstract contract LiquiditySeeder is IERC721Receiver {
  using SafeERC20 for IERC20;

  uint24 public constant POOL_FEE = 2500;
  int24 internal constant MAX_TICK = 887_272;

  INonfungiblePositionManager public immutable positionManager;
  IPancakeV3Factory public immutable pancakeFactory;

  uint256 public lpTokenId;
  address public lpPool;
  address private _swapPool;

  error UnexpectedCallback();

  event PoolPriceAligned(address indexed pool, uint160 fromSqrtPrice, uint160 toSqrtPrice);

  struct SeedPair {
    address token0;
    address token1;
    uint256 amount0;
    uint256 amount1;
    bool tokenIsZero;
  }

  constructor(address positionManager_, address pancakeFactory_) {
    positionManager = INonfungiblePositionManager(positionManager_);
    pancakeFactory = IPancakeV3Factory(pancakeFactory_);
  }

  /// @notice sqrt(price) in Q64.96 for the pool orientation; price is quote per 1e18 token units.
  /// @dev For token0 = launch token the raw ratio is price / 1e18; above ~1.8e37 the Q192 product would overflow,
  ///      so the Q128 form (shifted by 32 bits) is used there. Every price in [1, 2^128 - 1] maps inside
  ///      PancakeSwap V3's [MIN_SQRT_RATIO, MAX_SQRT_RATIO).
  function sqrtPriceX96For(uint256 price, bool tokenIsZero) public pure returns (uint160) {
    if (!tokenIsZero) return uint160(Math.sqrt(Math.mulDiv(LaunchConstants.PRICE_SCALE, 1 << 192, price)));
    if (price < (uint256(1) << 64) * LaunchConstants.PRICE_SCALE) {
      return uint160(Math.sqrt(Math.mulDiv(price, 1 << 192, LaunchConstants.PRICE_SCALE)));
    }
    return uint160(Math.sqrt(Math.mulDiv(price, 1 << 128, LaunchConstants.PRICE_SCALE)) << 32);
  }

  struct SeedOutcome {
    uint256 tokenUsed;
    uint256 quoteUsed;
    uint256 tokenLeft;
    uint256 quoteLeft;
  }

  /// @notice Create/initialise the pool at `price`, align it if needed and mint a full-range position.
  /// @dev tokenLeft / quoteLeft are the budget amounts (after any alignment swap) not placed in the position.
  function _seedLiquidity(
    address token,
    address quoteToken,
    uint256 tokenAmount,
    uint256 quoteAmount,
    uint256 price
  ) internal returns (SeedOutcome memory o) {
    SeedPair memory s;
    s.tokenIsZero = token < quoteToken;
    (s.token0, s.token1, s.amount0, s.amount1) =
      s.tokenIsZero ? (token, quoteToken, tokenAmount, quoteAmount) : (quoteToken, token, quoteAmount, tokenAmount);
    uint160 target = sqrtPriceX96For(price, s.tokenIsZero);
    address pool = positionManager.createAndInitializePoolIfNecessary(s.token0, s.token1, POOL_FEE, target);
    lpPool = pool;
    _alignPrice(pool, target, s);
    (uint256 used0, uint256 used1) = _mintFullRange(s);
    uint256 left0 = s.amount0 - used0;
    uint256 left1 = s.amount1 - used1;
    (o.tokenUsed, o.quoteUsed, o.tokenLeft, o.quoteLeft) =
      s.tokenIsZero ? (used0, used1, left0, left1) : (used1, used0, left1, left0);
  }

  /// @dev If someone initialised the pool at another price beforehand, swap toward the target using at most
  ///      the seeding budget. Before settlement nobody else holds launch tokens, so any pre-existing liquidity
  ///      is quote-only and can only be crossed at prices better than the target for this contract.
  function _alignPrice(address pool, uint160 target, SeedPair memory s) private {
    (uint160 current,,,,,,) = IPancakeV3Pool(pool).slot0();
    if (current == target) return;
    bool zeroForOne = current > target;
    uint256 budget = zeroForOne ? s.amount0 : s.amount1;
    if (budget == 0) return;
    _swapPool = pool;
    (int256 d0, int256 d1) =
      IPancakeV3Pool(pool).swap(address(this), zeroForOne, int256(budget), target, abi.encode(s.token0, s.token1));
    _swapPool = address(0);
    s.amount0 = _applyDelta(s.amount0, d0);
    s.amount1 = _applyDelta(s.amount1, d1);
    (uint160 after_,,,,,,) = IPancakeV3Pool(pool).slot0();
    emit PoolPriceAligned(pool, current, after_);
  }

  function _applyDelta(uint256 amount, int256 delta) private pure returns (uint256) {
    return delta >= 0 ? amount - uint256(delta) : amount + uint256(-delta);
  }

  function _mintFullRange(SeedPair memory s) private returns (uint256 used0, uint256 used1) {
    int24 spacing = pancakeFactory.feeAmountTickSpacing(POOL_FEE);
    // forge-lint: disable-next-line(divide-before-multiply)
    int24 upper = (MAX_TICK / spacing) * spacing;
    IERC20(s.token0).forceApprove(address(positionManager), s.amount0);
    IERC20(s.token1).forceApprove(address(positionManager), s.amount1);
    uint256 tokenId;
    (tokenId,, used0, used1) = positionManager.mint(
      INonfungiblePositionManager.MintParams({
        token0: s.token0,
        token1: s.token1,
        fee: POOL_FEE,
        tickLower: -upper,
        tickUpper: upper,
        amount0Desired: s.amount0,
        amount1Desired: s.amount1,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      })
    );
    IERC20(s.token0).forceApprove(address(positionManager), 0);
    IERC20(s.token1).forceApprove(address(positionManager), 0);
    lpTokenId = tokenId;
  }

  function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    if (msg.sender != _swapPool || msg.sender == address(0)) revert UnexpectedCallback();
    (address token0, address token1) = abi.decode(data, (address, address));
    if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
  }

  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }
}
