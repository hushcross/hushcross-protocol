// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {IERC6538Registry} from './IERC6538Registry.sol';

/// @notice ERC-1271 magic-value check used by the ERC-6538 reference registry.
interface IERC1271 {
  function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

/// @title ERC6538Registry
/// @notice Local-chain stealth meta-address registry. Body follows the CC0 example in ERC-6538.
/// @dev Deploy this only on a fresh local chain. Mainnet and forks use
/// `0x6538E6bf4B0eBd30A8Ea093027Ac2422ce5d6538`.
/// Spec: https://eips.ethereum.org/EIPS/eip-6538
contract ERC6538Registry is IERC6538Registry {
  /// @inheritdoc IERC6538Registry
  mapping(address registrant => mapping(uint256 schemeId => bytes)) public stealthMetaAddressOf;

  /// @inheritdoc IERC6538Registry
  mapping(address registrant => uint256) public nonceOf;

  /// @inheritdoc IERC6538Registry
  bytes32 public constant ERC6538REGISTRY_ENTRY_TYPE_HASH =
    keccak256('Erc6538RegistryEntry(uint256 schemeId,bytes stealthMetaAddress,uint256 nonce)');

  uint256 internal immutable INITIAL_CHAIN_ID;
  bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

  constructor() {
    INITIAL_CHAIN_ID = block.chainid;
    INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
  }

  /// @inheritdoc IERC6538Registry
  function registerKeys(uint256 schemeId, bytes calldata stealthMetaAddress) external {
    stealthMetaAddressOf[msg.sender][schemeId] = stealthMetaAddress;
    emit StealthMetaAddressSet(msg.sender, schemeId, stealthMetaAddress);
  }

  /// @inheritdoc IERC6538Registry
  function registerKeysOnBehalf(
    address registrant,
    uint256 schemeId,
    bytes memory signature,
    bytes calldata stealthMetaAddress
  ) external {
    bytes32 dataHash;
    address recoveredAddress;

    unchecked {
      dataHash = keccak256(
        abi.encodePacked(
          '\x19\x01',
          DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(ERC6538REGISTRY_ENTRY_TYPE_HASH, schemeId, keccak256(stealthMetaAddress), nonceOf[registrant]++)
          )
        )
      );
    }

    if (signature.length == 65) {
      bytes32 r;
      bytes32 s;
      uint8 v;
      assembly ('memory-safe') {
        r := mload(add(signature, 0x20))
        s := mload(add(signature, 0x40))
        v := byte(0, mload(add(signature, 0x60)))
      }
      recoveredAddress = ecrecover(dataHash, v, r, s);
    }

    if (
      (recoveredAddress == address(0) || recoveredAddress != registrant)
        && IERC1271(registrant).isValidSignature(dataHash, signature) != IERC1271.isValidSignature.selector
    ) revert ERC6538Registry__InvalidSignature();

    stealthMetaAddressOf[registrant][schemeId] = stealthMetaAddress;
    emit StealthMetaAddressSet(registrant, schemeId, stealthMetaAddress);
  }

  /// @inheritdoc IERC6538Registry
  function incrementNonce() external {
    unchecked {
      nonceOf[msg.sender]++;
    }
    emit NonceIncremented(msg.sender, nonceOf[msg.sender]);
  }

  /// @inheritdoc IERC6538Registry
  function DOMAIN_SEPARATOR() public view returns (bytes32) {
    return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
  }

  function _computeDomainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('ERC6538Registry'),
        keccak256('1.0'),
        block.chainid,
        address(this)
      )
    );
  }
}
