// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

/// @notice Registry surface from ERC-6538. The canonical BSC instance is
/// `0x6538E6bf4B0eBd30A8Ea093027Ac2422ce5d6538`.
/// @dev Spec: https://eips.ethereum.org/EIPS/eip-6538 (CC0).
interface IERC6538Registry {
  /// @notice Raised when `registerKeysOnBehalf` is given a signature the registrant did not produce.
  error ERC6538Registry__InvalidSignature();

  /// @notice A registrant published or replaced a stealth meta-address.
  event StealthMetaAddressSet(address indexed registrant, uint256 indexed schemeId, bytes stealthMetaAddress);

  /// @notice A registrant burned outstanding `registerKeysOnBehalf` signatures.
  event NonceIncremented(address indexed registrant, uint256 newNonce);

  function registerKeys(uint256 schemeId, bytes calldata stealthMetaAddress) external;

  function registerKeysOnBehalf(
    address registrant,
    uint256 schemeId,
    bytes memory signature,
    bytes calldata stealthMetaAddress
  ) external;

  function incrementNonce() external;

  function DOMAIN_SEPARATOR() external view returns (bytes32);

  function stealthMetaAddressOf(address registrant, uint256 schemeId) external view returns (bytes memory);

  function ERC6538REGISTRY_ENTRY_TYPE_HASH() external view returns (bytes32);

  function nonceOf(address registrant) external view returns (uint256);
}
