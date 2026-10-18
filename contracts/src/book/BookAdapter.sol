// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWBNB} from '../launch/interfaces/IWBNB.sol';
import {BookTypes} from './BookTypes.sol';
import {SealedBook} from './SealedBook.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/// @title BookAdapter
/// @notice Vault withdrawal processooor. Pulls a note into a sealed order and pays an absolute relay fee.
/// @dev The adapter's balance of the pool asset and of WBNB is unchanged when `fundOrder` returns.
contract BookAdapter is ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;
  using SafeERC20 for IERC20;

  struct FundData {
    uint256 marketId;
    bytes32 commitment;
    uint8 side;
    address feeRecipient;
    uint256 relayFee;
  }

  IEntrypoint public immutable entrypoint;
  SealedBook public immutable book;
  IWBNB public immutable wbnb;

  address private _activePool;

  error InvalidProcessooor();
  error UnknownPool();
  error AssetMismatch();
  error RelayFeeTooHigh();
  error WithdrawalMismatch();
  error ResidualBalance();
  error UnexpectedNative();
  error NativeTransferFailed();
  error InvalidConfig();
  error BadSide();

  event OrderFunded(address indexed pool, bytes32 indexed commitment, uint256 escrow, uint256 relayFee);

  constructor(address entrypoint_, address book_, address wbnb_) {
    if (entrypoint_.code.length == 0 || book_.code.length == 0 || wbnb_.code.length == 0) revert InvalidConfig();
    entrypoint = IEntrypoint(entrypoint_);
    book = SealedBook(payable(book_));
    wbnb = IWBNB(wbnb_);
  }

  receive() external payable {
    if (msg.sender != _activePool || msg.sender == address(0)) revert UnexpectedNative();
  }

  /// @notice Spend a vault note into `book.commit` bound to `commitment`.
  function fundOrder(
    IPrivacyPool pool,
    IPrivacyPool.Withdrawal calldata withdrawal,
    ProofLib.WithdrawProof calldata proof
  ) external nonReentrant {
    if (withdrawal.processooor != address(this)) {
      revert InvalidProcessooor();
    }
    FundData memory data = abi.decode(withdrawal.data, (FundData));
    if (address(entrypoint.scopeToPool(pool.SCOPE())) != address(pool)) revert UnknownPool();

    address poolAsset = pool.ASSET();
    bool native = poolAsset == BookTypes.NATIVE_ASSET;
    _checkAsset(data.marketId, data.side, poolAsset, native);

    uint256 withdrawn = proof.withdrawnValue();
    (,,, uint256 maxRelayFeeBps) = entrypoint.assetConfig(IERC20(poolAsset));
    if (data.relayFee > withdrawn || data.relayFee * BookTypes.BPS > withdrawn * maxRelayFeeBps) {
      revert RelayFeeTooHigh();
    }
    if (data.relayFee != 0 && data.feeRecipient == address(0)) revert InvalidConfig();

    uint256 nativeBefore = address(this).balance;
    uint256 wrappedBefore = wbnb.balanceOf(address(this));
    uint256 tokenBefore = native ? 0 : IERC20(poolAsset).balanceOf(address(this));

    _activePool = address(pool);
    pool.withdraw(withdrawal, proof);
    _activePool = address(0);

    uint256 got =
      native ? address(this).balance - nativeBefore : IERC20(poolAsset).balanceOf(address(this)) - tokenBefore;
    if (got != withdrawn) revert WithdrawalMismatch();

    uint256 escrow = withdrawn - data.relayFee;
    if (native) {
      wbnb.deposit{value: escrow}();
      IERC20(address(wbnb)).forceApprove(address(book), escrow);
      book.commit(data.marketId, data.commitment, data.side, escrow);
      IERC20(address(wbnb)).forceApprove(address(book), 0);
      if (data.relayFee != 0) {
        (bool ok,) = data.feeRecipient.call{value: data.relayFee}('');
        if (!ok) revert NativeTransferFailed();
      }
    } else {
      IERC20(poolAsset).forceApprove(address(book), escrow);
      book.commit(data.marketId, data.commitment, data.side, escrow);
      IERC20(poolAsset).forceApprove(address(book), 0);
      if (data.relayFee != 0) IERC20(poolAsset).safeTransfer(data.feeRecipient, data.relayFee);
    }

    if (address(this).balance != nativeBefore || wbnb.balanceOf(address(this)) != wrappedBefore) {
      revert ResidualBalance();
    }
    if (!native && IERC20(poolAsset).balanceOf(address(this)) != tokenBefore) revert ResidualBalance();
    emit OrderFunded(address(pool), data.commitment, escrow, data.relayFee);
  }

  function _checkAsset(uint256 marketId, uint8 side, address poolAsset, bool native) private view {
    (address base, address quote) = book.pairTokens(marketId);
    if (side == BookTypes.SIDE_BUY) {
      if (native || poolAsset != quote) revert AssetMismatch();
    } else if (side == BookTypes.SIDE_SELL) {
      if (base == address(wbnb)) {
        if (!native) revert AssetMismatch();
      } else if (native || poolAsset != base) {
        revert AssetMismatch();
      }
    } else {
      revert BadSide();
    }
  }
}
