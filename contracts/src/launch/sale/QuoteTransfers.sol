// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LaunchClearing} from '../LaunchClearing.sol';
import {LaunchConstants} from '../LaunchTypes.sol';
import {IWBNB} from '../interfaces/IWBNB.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';

/// @notice Quote-asset plumbing for a sale: escrow intake, payouts and vault re-deposits.
/// @dev quoteAsset == address(0) means native BNB.
abstract contract QuoteTransfers {
  using SafeERC20 for IERC20;

  address public immutable quoteAsset;
  IWBNB public immutable wbnb;
  IEntrypoint public immutable entrypoint;

  error InvalidPayment();
  error ZeroRecipient();
  error VaultDepositStarved();

  event VaultDeposit(uint256 indexed precommitment, uint256 unit, uint256 gross);
  event VaultDepositFailed(uint256 indexed precommitment, uint256 gross);

  constructor(address quoteAsset_, address wbnb_, address entrypoint_) {
    quoteAsset = quoteAsset_;
    wbnb = IWBNB(wbnb_);
    entrypoint = IEntrypoint(entrypoint_);
  }

  function _isNative() internal view returns (bool) {
    return quoteAsset == address(0);
  }

  function _vaultAsset() internal view returns (IERC20) {
    return IERC20(_isNative() ? LaunchConstants.VAULT_NATIVE_ASSET : quoteAsset);
  }

  function _pullQuote(address from, uint256 amount) internal {
    if (_isNative()) {
      if (msg.value != amount) revert InvalidPayment();
    } else {
      if (msg.value != 0) revert InvalidPayment();
      IERC20(quoteAsset).safeTransferFrom(from, address(this), amount);
    }
  }

  /// @dev Native sends fall back to WBNB when the recipient rejects BNB, so a payout can never block.
  function _sendQuote(address to, uint256 amount) internal {
    if (amount == 0) return;
    if (to == address(0)) revert ZeroRecipient();
    if (_isNative()) {
      (bool ok,) = to.call{value: amount}('');
      if (!ok) {
        wbnb.deposit{value: amount}();
        IERC20(address(wbnb)).safeTransfer(to, amount);
      }
    } else {
      IERC20(quoteAsset).safeTransfer(to, amount);
    }
  }

  /// @notice Smallest gross deposit whose post-vetting-fee value equals `unit` exactly.
  function grossForUnit(uint256 unit, uint256 feeBps) public pure returns (uint256) {
    return LaunchClearing.grossForNet(unit, feeBps);
  }

  /// @dev LAUNCH.md section 8: greedy largest-Unit-first split into at most `precommitments.length` (<= 16)
  ///      notes using the vault fee read now. A note whose deposit reverts with reason data (for example a used
  ///      precommitment) is added to the dust instead of failing the claim. A revert without data (out of gas)
  ///      fails the claim so a caller cannot starve the deposit to force funds out of the vault path.
  function _refundToVault(
    uint256 amount,
    uint256[] calldata precommitments,
    uint256[5] memory units
  ) internal returns (uint256 dust, uint256 notes) {
    IERC20 asset = _vaultAsset();
    (,, uint256 feeBps,) = entrypoint.assetConfig(asset);
    uint256 maxNotes = precommitments.length;
    uint256 remaining = amount;
    for (uint256 u = LaunchConstants.UNIT_COUNT; u != 0; --u) {
      uint256 gross = LaunchClearing.grossForNet(units[u - 1], feeBps);
      while (remaining >= gross && notes < maxNotes) {
        uint256 pc = precommitments[notes++];
        remaining -= gross;
        if (_tryDeposit(asset, gross, pc)) emit VaultDeposit(pc, units[u - 1], gross);
        else dust += gross;
      }
    }
    dust += remaining;
  }

  function _tryDeposit(IERC20 asset, uint256 gross, uint256 precommitment) private returns (bool ok) {
    bytes memory reason;
    if (_isNative()) {
      try entrypoint.deposit{value: gross}(precommitment) returns (uint256) {
        return true;
      } catch (bytes memory r) {
        reason = r;
      }
    } else {
      asset.forceApprove(address(entrypoint), gross);
      try entrypoint.deposit(asset, gross, precommitment) returns (uint256) {
        return true;
      } catch (bytes memory r) {
        reason = r;
        asset.forceApprove(address(entrypoint), 0);
      }
    }
    if (reason.length == 0) revert VaultDepositStarved();
    emit VaultDepositFailed(precommitment, gross);
  }
}
