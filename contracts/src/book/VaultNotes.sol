// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWBNB} from '../launch/interfaces/IWBNB.sol';
import {BookMath} from './BookMath.sol';
import {BookTypes} from './BookTypes.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';

/// @notice Greedy vault-note split (LAUNCH.md section 8). Public so each step is its own DELEGATECALL frame.
library VaultNotes {
  using SafeERC20 for IERC20;

  struct Run {
    address entrypoint;
    address wbnb;
    address quoteToken;
    bool native;
    uint256 feeBps;
    uint256 remaining;
    uint256 gross;
    uint256 cursor;
    uint256 dust;
    uint256 notes;
    uint256 unit;
    uint256 end;
  }

  event VaultNote(uint256 indexed precommitment, uint256 unit, uint256 gross);
  event VaultNoteFailed(uint256 indexed precommitment, uint256 gross);

  error VaultDepositStarved();

  /// @return dust Amount left for the recipient, in the same asset.
  /// @return notes Successful deposits.
  /// @return cursor Index of the first precommitment not consumed. Failures still consume their slot.
  function split(Run memory run, uint256[] calldata pcs) public returns (uint256 dust, uint256 notes, uint256 cursor) {
    IERC20 configAsset = IERC20(run.native ? BookTypes.NATIVE_ASSET : run.quoteToken);
    (,, run.feeBps,) = IEntrypoint(run.entrypoint).assetConfig(configAsset);
    uint256[5] memory units = run.native ? BookTypes.bnbUnits() : BookTypes.usdtUnits();
    uint256 u = 5;
    while (u > 0) {
      u -= 1;
      run.unit = units[u];
      run.gross = BookMath.grossForNet(run.unit, run.feeBps);
      while (run.remaining >= run.gross && run.cursor < run.end) {
        uint256 pc = pcs[run.cursor];
        run.cursor += 1;
        run.remaining -= run.gross;
        if (deposit(run, pc)) {
          run.notes += 1;
          emit VaultNote(pc, run.unit, run.gross);
        } else {
          run.dust += run.gross;
          emit VaultNoteFailed(pc, run.gross);
        }
      }
    }
    run.dust += run.remaining;
    return (run.dust, run.notes, run.cursor);
  }

  /// @dev Separate public function: try/catch does not fit in `split`'s frame under the legacy codegen.
  function deposit(Run memory run, uint256 precommitment) public returns (bool) {
    bytes memory reason;
    if (run.native) {
      IWBNB wrapped = IWBNB(run.wbnb);
      wrapped.withdraw(run.gross);
      try IEntrypoint(run.entrypoint).deposit{value: run.gross}(precommitment) returns (uint256) {
        return true;
      } catch (bytes memory bubbled) {
        reason = bubbled;
        wrapped.deposit{value: run.gross}();
      }
    } else {
      IERC20 token = IERC20(run.quoteToken);
      token.forceApprove(run.entrypoint, run.gross);
      try IEntrypoint(run.entrypoint).deposit(token, run.gross, precommitment) returns (uint256) {
        return true;
      } catch (bytes memory bubbled) {
        reason = bubbled;
        token.forceApprove(run.entrypoint, 0);
      }
    }
    if (reason.length == 0) revert VaultDepositStarved();
    return false;
  }
}
