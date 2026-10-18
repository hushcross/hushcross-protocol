// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {IERC5564Announcer} from './IERC5564Announcer.sol';

/// @title ERC5564Announcer
/// @notice Local-chain reference announcer. Logic follows the CC0 example in ERC-5564.
/// @dev Deploy this only on a fresh local chain. Mainnet and forks use the canonical
/// instance at `0x55649E01B5Df198D18D95b5cc5051630cfD45564`.
/// Spec: https://eips.ethereum.org/EIPS/eip-5564
contract ERC5564Announcer is IERC5564Announcer {
  /// @inheritdoc IERC5564Announcer
  function announce(
    uint256 schemeId,
    address stealthAddress,
    bytes memory ephemeralPubKey,
    bytes memory metadata
  ) external {
    emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata);
  }
}
