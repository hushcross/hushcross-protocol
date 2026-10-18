// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Constants} from 'contracts/lib/Constants.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {GiveEscrow} from './GiveEscrow.sol';
import {GiveRegistry} from './GiveRegistry.sol';

/// @title GiveAdapter
/// @notice Vault withdrawal processooor. Turns a private note into a campaign donation in one transaction.
/// @dev `withdrawal.data` is `abi.encode(GiveData)`. The upstream context signal binds that data to the proof.
///      `relayFee` is an absolute amount, capped by the pool's max relay fee in bps.
///      The adapter's native and asset balances end where they started. Balances are checked as deltas, so a
///      stray or forced transfer cannot block `fund`; such stray funds stay in the adapter and no call pays them out.
contract GiveAdapter is ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;
  using SafeERC20 for IERC20;

  uint256 internal constant BPS = 10_000;

  struct GiveData {
    uint256 campaignId;
    bytes32 receiptHash;
    uint256[] precommitments;
    address dustRecipient;
    address feeRecipient;
    uint256 relayFee;
  }

  IEntrypoint public immutable entrypoint;
  GiveEscrow public immutable escrow;

  /// @dev Pool allowed to push native coin into this contract during `fund`.
  address private _pulling;

  event GiveFunded(address indexed pool, uint256 indexed campaignId, uint256 donated, uint256 relayFee);

  error InvalidConfig();
  error InvalidProcessooor();
  error UnknownPool();
  error AssetMismatch();
  error RelayFeeTooHigh();
  error ZeroDonation();
  error FeeRecipient();
  error WithdrawalMismatch();
  error ResidualBalance();
  error TransferFailed();
  error DirectTransferRejected();

  constructor(address entrypoint_, address escrow_) {
    if (entrypoint_.code.length == 0 || escrow_.code.length == 0) revert InvalidConfig();
    entrypoint = IEntrypoint(entrypoint_);
    escrow = GiveEscrow(payable(escrow_));
  }

  receive() external payable {
    if (msg.sender != _pulling) revert DirectTransferRejected();
  }

  /// @notice Spend a vault note into `GiveData.campaignId`.
  function fund(
    address pool,
    IPrivacyPool.Withdrawal calldata withdrawal,
    ProofLib.WithdrawProof calldata proof
  ) external nonReentrant {
    if (withdrawal.processooor != address(this)) revert InvalidProcessooor();
    GiveData memory data = abi.decode(withdrawal.data, (GiveData));
    (bool native, address asset, uint256 donation) = _check(pool, data, proof.withdrawnValue());

    uint256 nativeBefore = address(this).balance;
    uint256 assetBefore = _balance(native, asset);
    _pulling = pool;
    IPrivacyPool(pool).withdraw(withdrawal, proof);
    _pulling = address(0);
    if (_balance(native, asset) - assetBefore != proof.withdrawnValue()) revert WithdrawalMismatch();
    if (!native && address(this).balance != nativeBefore) revert ResidualBalance();

    if (native) {
      escrow.donateFromAdapter{value: donation}(
        data.campaignId, donation, data.receiptHash, data.dustRecipient, data.precommitments
      );
      _pushNative(data.feeRecipient, data.relayFee);
    } else {
      IERC20 token = IERC20(asset);
      token.forceApprove(address(escrow), donation);
      escrow.donateFromAdapter(data.campaignId, donation, data.receiptHash, data.dustRecipient, data.precommitments);
      token.forceApprove(address(escrow), 0);
      if (data.relayFee != 0) token.safeTransfer(data.feeRecipient, data.relayFee);
    }

    _assertUnchanged(native, asset, nativeBefore, assetBefore);
    emit GiveFunded(pool, data.campaignId, donation, data.relayFee);
  }

  function _check(
    address pool,
    GiveData memory data,
    uint256 withdrawn
  ) internal view returns (bool native, address asset, uint256 donation) {
    if (withdrawn == 0 || data.relayFee >= withdrawn) revert ZeroDonation();
    asset = IPrivacyPool(pool).ASSET();
    native = asset == Constants.NATIVE_ASSET;
    (IPrivacyPool registered,,, uint256 maxRelayBps) = entrypoint.assetConfig(IERC20(asset));
    if (address(registered) != pool) revert UnknownPool();
    if (data.relayFee > Math.mulDiv(withdrawn, maxRelayBps, BPS)) revert RelayFeeTooHigh();
    if (data.relayFee != 0 && (data.feeRecipient == address(0) || data.feeRecipient == address(this))) {
      revert FeeRecipient();
    }

    GiveRegistry.Campaign memory campaign = escrow.registry().campaign(data.campaignId);
    if (native ? campaign.asset != address(0) : campaign.asset != asset) revert AssetMismatch();
    donation = withdrawn - data.relayFee;
  }

  function _assertUnchanged(bool native, address asset, uint256 nativeBefore, uint256 assetBefore) internal view {
    if (address(this).balance != nativeBefore) revert ResidualBalance();
    if (!native && IERC20(asset).balanceOf(address(this)) != assetBefore) revert ResidualBalance();
  }

  function _balance(bool native, address asset) internal view returns (uint256) {
    return native ? address(this).balance : IERC20(asset).balanceOf(address(this));
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
}
