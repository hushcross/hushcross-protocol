// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SaleConfig} from './LaunchTypes.sol';
import {SealedSale} from './SealedSale.sol';

/// @notice Holds the SealedSale creation code so LaunchFactory stays under the EIP-170 size limit.
/// @dev Permissionless but the caller must name itself as `factory`; only LaunchFactory.isSale is authoritative.
contract SaleDeployer {
  error FactoryMismatch();

  function deploy(SaleConfig calldata c) external returns (address sale) {
    if (c.factory != msg.sender) revert FactoryMismatch();
    sale = address(new SealedSale(c));
  }
}
