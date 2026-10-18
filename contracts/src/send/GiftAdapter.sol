// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {Constants} from 'contracts/lib/Constants.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/// @title GiftAdapter
/// @notice Processooor that splits one vault withdrawal into up to 16 deposits in the same pool.
/// @dev Used both to fund gift notes and to claim a gift note into the recipient's own precommitments.
///      `withdrawal.data` is `abi.encode(GiftData)`. `values[i]` is the gross deposit for `precommitments[i]`.
///      Withdrawn = relay fee + sum(values) + dust. Dust is paid to `dustRecipient`. The adapter's native and
///      pool-asset balances end where they started. Balances are checked as deltas, so a stray or forced transfer
///      cannot block `gift`; such stray funds stay in the adapter and no call can pay them out.
contract GiftAdapter is ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;
  using SafeERC20 for IERC20;

  uint256 public constant MAX_SHARES = 16;
  uint256 public constant BPS_DENOMINATOR = 10_000;

  IEntrypoint public immutable ENTRYPOINT;

  /// @dev Pool allowed to push native coin into this contract during `gift`.
  address private pullingFrom;

  /// @param precommitments One fresh precommitment per share. Duplicates are rejected.
  /// @param values Gross deposit of each share. Each one must be at least the pool minimum.
  /// @param feeRecipient Receives the relay fee when that fee rounds above zero.
  /// @param relayFeeBPS Relay fee in basis points, at most the pool cap.
  /// @param dustRecipient Receives `withdrawn - fee - sum(values)` when that dust is non-zero.
  struct GiftData {
    uint256[] precommitments;
    uint256[] values;
    address feeRecipient;
    uint256 relayFeeBPS;
    address dustRecipient;
  }

  event GiftFunded(address indexed pool, uint256 count, uint256 total, uint256 fee, uint256 dust);

  error ZeroAddress();
  error InvalidProcessooor();
  error PoolNotRegistered();
  error ShareCount();
  error LengthMismatch();
  error DuplicatePrecommitment(uint256 precommitment);
  error BelowMinimum(uint256 index, uint256 value, uint256 minimum);
  error RelayFeeExceedsCap(uint256 feeBPS, uint256 maxBPS);
  error InvalidWithdrawalAmount();
  error SharesExceedWithdrawal(uint256 total, uint256 available);
  error InvalidRecipient();
  error AmountMismatch(uint256 expected, uint256 actual);
  error UnexpectedBalance();
  error TransferFailed();
  error DirectTransferRejected();

  /// @param entrypoint Entrypoint that registered the pools this adapter may spend from and deposit into.
  constructor(address entrypoint) {
    if (entrypoint == address(0)) revert ZeroAddress();
    ENTRYPOINT = IEntrypoint(entrypoint);
  }

  /// @notice Accept native coin only from the pool currently being withdrawn.
  receive() external payable {
    if (msg.sender != pullingFrom) revert DirectTransferRejected();
  }

  /// @notice Withdraw `proof.withdrawnValue()` from `pool` and deposit it back as `GiftData` shares.
  /// @param pool Native or token Privacy Pool registered on `ENTRYPOINT`.
  /// @param withdrawal Processooor and ABI-encoded `GiftData`.
  /// @param proof Groth16 withdrawal proof consumed by `pool`.
  function gift(
    address pool,
    IPrivacyPool.Withdrawal calldata withdrawal,
    ProofLib.WithdrawProof calldata proof
  ) external nonReentrant {
    if (withdrawal.processooor != address(this)) revert InvalidProcessooor();
    GiftData memory data = abi.decode(withdrawal.data, (GiftData));
    uint256 count = data.precommitments.length;
    if (count == 0 || count > MAX_SHARES) revert ShareCount();
    if (data.values.length != count) revert LengthMismatch();
    _rejectDuplicates(data.precommitments);

    uint256 withdrawn = proof.withdrawnValue();
    if (withdrawn == 0) revert InvalidWithdrawalAmount();

    address asset = IPrivacyPool(pool).ASSET();
    bool nativeAsset = asset == Constants.NATIVE_ASSET;
    (uint256 minimum, uint256 maxRelayFeeBPS) = _poolConfig(asset, pool);
    if (data.relayFeeBPS > maxRelayFeeBPS) revert RelayFeeExceedsCap(data.relayFeeBPS, maxRelayFeeBPS);

    (uint256 total, uint256 fee, uint256 dust) = _split(withdrawn, data, minimum);
    if (fee != 0 && !_canReceive(data.feeRecipient)) revert InvalidRecipient();
    if (dust != 0 && !_canReceive(data.dustRecipient)) revert InvalidRecipient();
    uint256 nativeBefore = address(this).balance;
    uint256 tokenBefore = nativeAsset ? 0 : IERC20(asset).balanceOf(address(this));

    pullingFrom = pool;
    IPrivacyPool(pool).withdraw(withdrawal, proof);
    pullingFrom = address(0);

    if (nativeAsset) _settleNative(data, withdrawn, fee, dust, nativeBefore);
    else _settleToken(IERC20(asset), data, withdrawn, total, fee, dust, nativeBefore, tokenBefore);

    if (address(this).balance != nativeBefore) revert UnexpectedBalance();
    if (!nativeAsset && IERC20(asset).balanceOf(address(this)) != tokenBefore) revert UnexpectedBalance();

    emit GiftFunded(pool, count, total, fee, dust);
  }

  function _poolConfig(address asset, address pool) internal view returns (uint256 minimum, uint256 maxRelayFeeBPS) {
    IPrivacyPool registered;
    (registered, minimum,, maxRelayFeeBPS) = ENTRYPOINT.assetConfig(IERC20(asset));
    if (address(registered) != pool) revert PoolNotRegistered();
  }

  function _split(
    uint256 withdrawn,
    GiftData memory data,
    uint256 minimum
  ) internal pure returns (uint256 total, uint256 fee, uint256 dust) {
    total = _sumAtLeastMinimum(data.values, minimum);
    fee = (withdrawn * data.relayFeeBPS) / BPS_DENOMINATOR;
    if (total > withdrawn - fee) revert SharesExceedWithdrawal(total, withdrawn - fee);
    dust = withdrawn - fee - total;
  }

  function _settleNative(
    GiftData memory data,
    uint256 withdrawn,
    uint256 fee,
    uint256 dust,
    uint256 nativeBefore
  ) internal {
    uint256 got = address(this).balance - nativeBefore;
    if (got != withdrawn) revert AmountMismatch(withdrawn, got);
    _pushNative(data.feeRecipient, fee);
    uint256 count = data.precommitments.length;
    for (uint256 i; i < count; ++i) {
      ENTRYPOINT.deposit{value: data.values[i]}(data.precommitments[i]);
    }
    _pushNative(data.dustRecipient, dust);
  }

  function _settleToken(
    IERC20 asset,
    GiftData memory data,
    uint256 withdrawn,
    uint256 total,
    uint256 fee,
    uint256 dust,
    uint256 nativeBefore,
    uint256 tokenBefore
  ) internal {
    if (address(this).balance != nativeBefore) revert UnexpectedBalance();
    uint256 got = asset.balanceOf(address(this)) - tokenBefore;
    if (got != withdrawn) revert AmountMismatch(withdrawn, got);
    _pushToken(asset, data.feeRecipient, fee);
    asset.forceApprove(address(ENTRYPOINT), total);
    uint256 count = data.precommitments.length;
    for (uint256 i; i < count; ++i) {
      ENTRYPOINT.deposit(asset, data.values[i], data.precommitments[i]);
    }
    asset.forceApprove(address(ENTRYPOINT), 0);
    _pushToken(asset, data.dustRecipient, dust);
  }

  function _sumAtLeastMinimum(uint256[] memory values, uint256 minimum) internal pure returns (uint256 total) {
    uint256 n = values.length;
    for (uint256 i; i < n; ++i) {
      if (values[i] < minimum) revert BelowMinimum(i, values[i], minimum);
      total += values[i];
    }
  }

  function _rejectDuplicates(uint256[] memory ids) internal pure {
    uint256 n = ids.length;
    for (uint256 i; i < n; ++i) {
      for (uint256 j = i + 1; j < n; ++j) {
        if (ids[i] == ids[j]) revert DuplicatePrecommitment(ids[i]);
      }
    }
  }

  function _canReceive(address account) internal view returns (bool) {
    return account != address(0) && account != address(this);
  }

  function _pushNative(address to, uint256 amount) internal {
    if (amount == 0) return;
    (bool ok, bytes memory reason) = to.call{value: amount}('');
    if (ok) return;
    if (reason.length == 0) revert TransferFailed();
    assembly {
      revert(add(reason, 32), mload(reason))
    }
  }

  function _pushToken(IERC20 token, address to, uint256 amount) internal {
    if (amount == 0) return;
    token.safeTransfer(to, amount);
  }
}
