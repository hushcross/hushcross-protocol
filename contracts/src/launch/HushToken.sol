// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';

/// @title HushToken
/// @notice Plain fixed-supply ERC-20 with EIP-2612 permit. The whole supply is minted once in the constructor;
///         there is no owner, mint, tax, blacklist or pause.
contract HushToken is ERC20, ERC20Permit {
  constructor(
    string memory name_,
    string memory symbol_,
    uint256 supply,
    address recipient
  ) ERC20(name_, symbol_) ERC20Permit(name_) {
    _mint(recipient, supply);
  }
}
