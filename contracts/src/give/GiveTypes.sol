// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Shared Give constants. A library so other contracts can read them at compile time.
library GiveTypes {
  uint8 internal constant KIND_TIP = 0;
  uint8 internal constant KIND_GOAL = 1;
  uint256 internal constant MAX_TITLE_BYTES = 240;
  uint256 internal constant MAX_URI_BYTES = 256;
  uint64 internal constant MIN_DURATION = 1 hours;
  uint64 internal constant MAX_DURATION = 90 days;
  uint256 internal constant MAX_AMOUNT = type(uint128).max;
}
