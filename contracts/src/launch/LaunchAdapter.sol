// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LaunchConstants} from './LaunchTypes.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

interface ILaunchFactoryRegistry {
  function isSale(address sale) external view returns (bool);
}

interface ISealedSaleEscrow {
  function quoteAsset() external view returns (address);

  function commit(bytes32 commitment, uint256 amount) external payable returns (uint256 bidId);
}

/// @title LaunchAdapter
/// @notice Vault withdrawal `processooor` that turns a private withdrawal into a sealed-bid escrow.
/// @dev Flow: anyone (normally the relay) calls `fundBid`; the adapter calls `pool.withdraw` (the pool only
///      accepts `msg.sender == processooor`), receives `withdrawnValue`, escrows `withdrawnValue - relayFee`
///      into the sale bound to the commitment, and pays `relayFee` to `feeRecipient`. The withdrawal `data`
///      (sale, commitment, feeRecipient, relayFee) is bound to the proof through the upstream `context` signal.
///      The adapter never keeps a balance: it asserts its balance is unchanged after every call.
contract LaunchAdapter is ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;
  using SafeERC20 for IERC20;

  struct FundData {
    address sale;
    bytes32 commitment;
    address feeRecipient;
    uint256 relayFee;
  }

  IEntrypoint public immutable entrypoint;
  ILaunchFactoryRegistry public immutable factory;

  address private _activePool;

  error InvalidProcessooor();
  error UnknownSale();
  error UnknownPool();
  error AssetMismatch();
  error RelayFeeTooHigh();
  error WithdrawalMismatch();
  error ResidualBalance();
  error UnexpectedNative();
  error NativeTransferFailed();
  error InvalidConfig();

  event BidFunded(
    address indexed sale, uint256 indexed bidId, bytes32 indexed commitment, uint256 escrow, uint256 relayFee
  );

  constructor(address entrypoint_, address factory_) {
    if (entrypoint_.code.length == 0 || factory_.code.length == 0) revert InvalidConfig();
    entrypoint = IEntrypoint(entrypoint_);
    factory = ILaunchFactoryRegistry(factory_);
  }

  receive() external payable {
    if (msg.sender != _activePool || msg.sender == address(0)) revert UnexpectedNative();
  }

  /// @notice Spend a vault note into a sealed-bid escrow in one transaction.
  function fundBid(
    IPrivacyPool pool,
    IPrivacyPool.Withdrawal calldata withdrawal,
    ProofLib.WithdrawProof calldata proof
  ) external nonReentrant returns (uint256 bidId) {
    if (withdrawal.processooor != address(this)) revert InvalidProcessooor();
    FundData memory d = abi.decode(withdrawal.data, (FundData));
    if (!factory.isSale(d.sale)) revert UnknownSale();
    if (address(entrypoint.scopeToPool(pool.SCOPE())) != address(pool)) revert UnknownPool();

    address poolAsset = pool.ASSET();
    bool native = poolAsset == LaunchConstants.VAULT_NATIVE_ASSET;
    address saleAsset = ISealedSaleEscrow(d.sale).quoteAsset();
    if (native ? saleAsset != address(0) : saleAsset != poolAsset) revert AssetMismatch();

    uint256 withdrawn = proof.withdrawnValue();
    (,,, uint256 maxRelayFeeBps) = entrypoint.assetConfig(IERC20(poolAsset));
    if (d.relayFee * LaunchConstants.BPS > withdrawn * maxRelayFeeBps) revert RelayFeeTooHigh();

    uint256 balanceBefore = _balance(native, poolAsset);
    _activePool = address(pool);
    pool.withdraw(withdrawal, proof);
    _activePool = address(0);
    if (_balance(native, poolAsset) - balanceBefore != withdrawn) revert WithdrawalMismatch();

    uint256 escrow = withdrawn - d.relayFee;
    if (native) {
      bidId = ISealedSaleEscrow(d.sale).commit{value: escrow}(d.commitment, escrow);
      if (d.relayFee != 0) {
        (bool ok,) = d.feeRecipient.call{value: d.relayFee}('');
        if (!ok) revert NativeTransferFailed();
      }
    } else {
      IERC20(poolAsset).forceApprove(d.sale, escrow);
      bidId = ISealedSaleEscrow(d.sale).commit(d.commitment, escrow);
      IERC20(poolAsset).forceApprove(d.sale, 0);
      if (d.relayFee != 0) IERC20(poolAsset).safeTransfer(d.feeRecipient, d.relayFee);
    }
    if (_balance(native, poolAsset) != balanceBefore) revert ResidualBalance();
    emit BidFunded(d.sale, bidId, d.commitment, escrow, d.relayFee);
  }

  function _balance(bool native, address asset) private view returns (uint256) {
    return native ? address(this).balance : IERC20(asset).balanceOf(address(this));
  }
}
