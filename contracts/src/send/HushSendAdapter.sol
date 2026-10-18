// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {IERC5564Announcer} from '../standards/IERC5564Announcer.sol';
import {Constants} from 'contracts/lib/Constants.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/// @notice Entrypoint view used to read the relay-fee cap registered for an asset.
interface IVaultConfig {
  function assetConfig(IERC20 asset)
    external
    view
    returns (address pool, uint256 minimumDepositAmount, uint256 vettingFeeBPS, uint256 maxRelayFeeBPS);
}

/// @title HushSendAdapter
/// @notice Processooor for a Privacy Pool withdrawal. One call pulls one or more units from a
/// native or token pool, pays the relay fee, forwards the remainder, optionally announces an
/// ERC-5564 scheme-1 stealth address, and forwards any `msg.value` gas stipend.
/// @dev `withdrawal.data` is `abi.encode(SendData)`. The pool binds that encoding into the
/// withdrawal proof context, so a relayer cannot swap the recipient after the proof is built.
/// `send` leaves the adapter's native and pool-asset balances exactly as it found them. Balances are
/// checked as deltas, so a stray transfer (or a forced SELFDESTRUCT payment) cannot block it; such
/// stray funds stay in the adapter and no call can pay them out.
contract HushSendAdapter is ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;
  using SafeERC20 for IERC20;

  /// @notice ERC-5564 scheme 1: secp256k1 with a view tag.
  uint256 public constant SCHEME_ID = 1;
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @notice Privacy Pool entrypoint whose `assetConfig` stores the relay-fee cap.
  IVaultConfig public immutable ENTRYPOINT;
  /// @notice Announcer. On BSC this is the canonical ERC-5564 instance.
  IERC5564Announcer public immutable ANNOUNCER;

  /// @dev Pool that is allowed to push native coin into this contract during `send`.
  address private pullingFrom;

  /// @notice Where the withdrawn funds go, and the stealth address when an announcement is attached.
  /// @param recipient Account that receives the amount after the relay fee, plus any gas stipend.
  /// @param feeRecipient Account that receives the relay fee. Required when the fee rounds above zero.
  /// @param relayFeeBPS Relay fee in basis points. Must be less than or equal to the pool's cap.
  /// @param ephemeralPubKey ERC-5564 ephemeral public key. Empty, together with `metadata`, means no announcement.
  /// @param metadata ERC-5564 metadata. The first byte is the view tag.
  struct SendData {
    address recipient;
    address feeRecipient;
    uint256 relayFeeBPS;
    bytes ephemeralPubKey;
    bytes metadata;
  }

  /// @notice A withdrawal was split between the recipient and the fee recipient.
  event HushSent(
    address indexed pool,
    address indexed recipient,
    address indexed caller,
    address asset,
    uint256 withdrawn,
    uint256 fee,
    uint256 stipend,
    bool announced
  );

  error ZeroAddress();
  error InvalidRecipient();
  error InvalidProcessooor();
  error PoolNotRegistered();
  error RelayFeeExceedsCap(uint256 feeBPS, uint256 maxBPS);
  error InvalidWithdrawalAmount();
  error InvalidAnnouncement();
  error AmountMismatch(uint256 expected, uint256 actual);
  error UnexpectedBalance();
  error TransferFailed();
  error DirectTransferRejected();

  /// @param entrypoint Entrypoint that registered the pools this adapter may spend from.
  /// @param announcer ERC-5564 announcer. Local chains use the reference contract; BSC uses the canonical one.
  constructor(address entrypoint, address announcer) {
    if (entrypoint == address(0) || announcer == address(0)) revert ZeroAddress();
    ENTRYPOINT = IVaultConfig(entrypoint);
    ANNOUNCER = IERC5564Announcer(announcer);
  }

  /// @notice Accept native coin only from the pool currently being withdrawn.
  receive() external payable {
    if (msg.sender != pullingFrom) revert DirectTransferRejected();
  }

  /// @notice Withdraw `proof.withdrawnValue()` from `pool` and deliver it according to `withdrawal.data`.
  /// @dev `withdrawal.processooor` must be this contract. `msg.value` is a gas stipend from the relayer
  /// and is forwarded in full to `SendData.recipient` on top of the withdrawn funds. The call reverts
  /// unless this contract's native and pool-asset balances end where they started.
  /// @param pool Native or token Privacy Pool registered on `ENTRYPOINT`.
  /// @param withdrawal Processooor and ABI-encoded `SendData`.
  /// @param proof Groth16 withdrawal proof consumed by `pool`.
  function send(
    IPrivacyPool pool,
    IPrivacyPool.Withdrawal calldata withdrawal,
    ProofLib.WithdrawProof calldata proof
  ) external payable nonReentrant {
    if (withdrawal.processooor != address(this)) revert InvalidProcessooor();
    uint256 withdrawn = proof.withdrawnValue();
    if (withdrawn == 0) revert InvalidWithdrawalAmount();

    SendData memory data = abi.decode(withdrawal.data, (SendData));
    if (data.recipient == address(0) || data.recipient == address(this)) revert InvalidRecipient();

    bool announced = data.ephemeralPubKey.length != 0 || data.metadata.length != 0;
    if (announced && (data.ephemeralPubKey.length == 0 || data.metadata.length == 0)) revert InvalidAnnouncement();

    address asset = pool.ASSET();
    bool nativeAsset = asset == Constants.NATIVE_ASSET;
    {
      (address registered,,, uint256 maxRelayFeeBPS) = ENTRYPOINT.assetConfig(IERC20(asset));
      if (registered != address(pool)) revert PoolNotRegistered();
      if (data.relayFeeBPS > maxRelayFeeBPS) revert RelayFeeExceedsCap(data.relayFeeBPS, maxRelayFeeBPS);
    }

    (uint256 nativeBefore, uint256 tokenBefore) = _pull(pool, withdrawal, proof, asset, nativeAsset, withdrawn);

    uint256 fee = (withdrawn * data.relayFeeBPS) / BPS_DENOMINATOR;
    if (fee != 0 && (data.feeRecipient == address(0) || data.feeRecipient == address(this))) {
      revert InvalidRecipient();
    }

    if (announced) ANNOUNCER.announce(SCHEME_ID, data.recipient, data.ephemeralPubKey, data.metadata);

    if (nativeAsset) {
      _pushNative(data.feeRecipient, fee);
      _pushNative(data.recipient, withdrawn - fee + msg.value);
    } else {
      _pushToken(IERC20(asset), data.feeRecipient, fee);
      _pushToken(IERC20(asset), data.recipient, withdrawn - fee);
      _pushNative(data.recipient, msg.value);
    }

    if (address(this).balance != nativeBefore) revert UnexpectedBalance();
    if (!nativeAsset && IERC20(asset).balanceOf(address(this)) != tokenBefore) revert UnexpectedBalance();

    emit HushSent(address(pool), data.recipient, msg.sender, asset, withdrawn, fee, msg.value, announced);
  }

  /// @dev Snapshot, withdraw, and check that exactly `withdrawn` arrived. `msg.value` is excluded from the snapshot.
  function _pull(
    IPrivacyPool pool,
    IPrivacyPool.Withdrawal calldata withdrawal,
    ProofLib.WithdrawProof calldata proof,
    address asset,
    bool nativeAsset,
    uint256 withdrawn
  ) internal returns (uint256 nativeBefore, uint256 tokenBefore) {
    nativeBefore = address(this).balance - msg.value;
    tokenBefore = nativeAsset ? 0 : IERC20(asset).balanceOf(address(this));

    pullingFrom = address(pool);
    pool.withdraw(withdrawal, proof);
    pullingFrom = address(0);

    uint256 got;
    if (nativeAsset) {
      got = address(this).balance - msg.value - nativeBefore;
    } else {
      if (address(this).balance != msg.value + nativeBefore) revert UnexpectedBalance();
      got = IERC20(asset).balanceOf(address(this)) - tokenBefore;
    }
    if (got != withdrawn) revert AmountMismatch(withdrawn, got);
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
