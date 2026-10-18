// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

/// @notice Announcement surface from ERC-5564. The canonical BSC instance is
/// `0x55649E01B5Df198D18D95b5cc5051630cfD45564`.
/// @dev Spec: https://eips.ethereum.org/EIPS/eip-5564 (CC0).
interface IERC5564Announcer {
  /// @notice Emitted when a sender announces a stealth-address transfer.
  /// @param schemeId Stealth scheme. Scheme 1 is secp256k1 with a view tag.
  /// @param stealthAddress Address that can spend the transfer.
  /// @param caller Account that submitted the announcement.
  /// @param ephemeralPubKey Ephemeral public key used to derive the stealth address.
  /// @param metadata First byte is the view tag. Remaining bytes are caller-defined.
  event Announcement(
    uint256 indexed schemeId,
    address indexed stealthAddress,
    address indexed caller,
    bytes ephemeralPubKey,
    bytes metadata
  );

  /// @notice Emit an `Announcement` for `stealthAddress`.
  function announce(
    uint256 schemeId,
    address stealthAddress,
    bytes memory ephemeralPubKey,
    bytes memory metadata
  ) external;
}
