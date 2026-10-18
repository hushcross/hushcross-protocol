// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @notice Vetting-fee inversion and the vault-unit split used when a failed goal refunds into the pool.
/// @dev `grossForNet` is the smallest gross whose post-fee net is exactly `net`, using the same truncation as
///      Entrypoint: `net = gross - floor(gross * feeBps / 10_000)`. Units are the standard denominations,
///      largest first. At most 16 notes. Anything that does not fill another allowed note is dust.
library GiveMath {
  uint256 internal constant BPS = 10_000;
  uint256 internal constant MAX_NOTES = 16;

  error FeeTooHigh(uint256 feeBps);

  function grossForNet(uint256 net, uint256 feeBps) internal pure returns (uint256) {
    if (feeBps >= BPS) revert FeeTooHigh(feeBps);
    if (net == 0) return 0;
    return Math.mulDiv(net - 1, BPS, BPS - feeBps) + 1;
  }

  function netOf(uint256 gross, uint256 feeBps) internal pure returns (uint256) {
    if (feeBps >= BPS) revert FeeTooHigh(feeBps);
    return gross - Math.mulDiv(gross, feeBps, BPS);
  }

  /// @notice Greedy largest-unit split. `maxNotes` above 16 is capped. Notes below `minimum` are skipped.
  function allocate(
    uint256 amount,
    uint256 feeBps,
    uint256[5] memory unitsDesc,
    uint256 maxNotes,
    uint256 minimum
  ) internal pure returns (uint256 count, uint256[16] memory grosses, uint256[16] memory nets, uint256 dust) {
    if (maxNotes > MAX_NOTES) maxNotes = MAX_NOTES;
    uint256 remaining = amount;
    uint256 n = unitsDesc.length;
    for (uint256 u; u < n; ++u) {
      uint256 gross = grossForNet(unitsDesc[u], feeBps);
      if (gross == 0 || gross < minimum) continue;
      while (remaining >= gross && count < maxNotes) {
        grosses[count] = gross;
        nets[count] = unitsDesc[u];
        remaining -= gross;
        unchecked {
          ++count;
        }
      }
    }
    dust = remaining;
  }

  function bnbUnits() internal pure returns (uint256[5] memory units) {
    units = [uint256(10 ether), 2 ether, 0.5 ether, 0.1 ether, 0.02 ether];
  }

  function usdtUnits() internal pure returns (uint256[5] memory units) {
    units = [uint256(10_000 ether), 2000 ether, 500 ether, 100 ether, 20 ether];
  }
}
