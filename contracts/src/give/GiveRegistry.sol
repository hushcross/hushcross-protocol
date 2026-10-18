// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GiveTypes} from './GiveTypes.sol';

/// @notice Campaign catalogue for Give. Money and the indexer events live on GiveEscrow.
/// @dev Native campaigns use `asset == address(0)` so the indexer can label them BNB.
///      `metadataURI` is an off-chain document (the campaign story is not stored here).
///      Deadlines are absolute unix seconds. A goal must last between 1 hour and 90 days.
contract GiveRegistry {
  uint8 public constant KIND_TIP = GiveTypes.KIND_TIP;
  uint8 public constant KIND_GOAL = GiveTypes.KIND_GOAL;
  uint256 public constant MAX_TITLE_BYTES = GiveTypes.MAX_TITLE_BYTES;
  uint256 public constant MAX_URI_BYTES = GiveTypes.MAX_URI_BYTES;
  uint64 public constant MIN_DURATION = GiveTypes.MIN_DURATION;
  uint64 public constant MAX_DURATION = GiveTypes.MAX_DURATION;
  uint256 public constant MAX_AMOUNT = GiveTypes.MAX_AMOUNT;

  struct Campaign {
    address beneficiary;
    address asset;
    uint8 kind;
    uint64 deadline;
    uint256 goal;
    address creator;
    string title;
    string metadataURI;
  }

  address public immutable usdt;
  address public escrow;

  uint256 public nextId = 1;
  mapping(uint256 id => Campaign) private _campaigns;
  address private _deployer;

  error InvalidConfig();
  error NotDeployer();
  error NotEscrow();
  error BadKind();
  error BadAsset();
  error BadBeneficiary();
  error BadGoal();
  error BadDeadline();
  error TitleLength();
  error UriLength();
  error UnknownCampaign();

  constructor(address usdt_) {
    if (usdt_.code.length == 0) revert InvalidConfig();
    usdt = usdt_;
    _deployer = msg.sender;
  }

  /// @notice One-time wiring. Only the deployer (the deploy script) can call it, once.
  function linkEscrow(address escrow_) external {
    if (msg.sender != _deployer) revert NotDeployer();
    if (escrow != address(0)) revert NotEscrow();
    if (escrow_.code.length == 0) revert InvalidConfig();
    if (IGiveEscrowView(escrow_).registry() != address(this)) revert InvalidConfig();
    if (IGiveEscrowView(escrow_).usdt() != usdt) revert InvalidConfig();
    escrow = escrow_;
    _deployer = address(0);
  }

  function campaignCount() external view returns (uint256) {
    return nextId - 1;
  }

  function campaign(uint256 id) external view returns (Campaign memory) {
    if (id == 0 || id >= nextId) revert UnknownCampaign();
    return _campaigns[id];
  }

  /// @notice Called by the escrow. Ids start at 1.
  function create(
    address creator,
    uint8 kind,
    address asset,
    address beneficiary,
    uint256 goal,
    uint64 deadline,
    string calldata title,
    string calldata metadataURI
  ) external returns (uint256 id) {
    if (msg.sender != escrow) revert NotEscrow();
    if (kind != KIND_TIP && kind != KIND_GOAL) revert BadKind();
    if (asset != address(0) && asset != usdt) revert BadAsset();
    if (beneficiary == address(0) || beneficiary == address(this) || beneficiary == escrow) revert BadBeneficiary();
    uint256 titleBytes = bytes(title).length;
    if (titleBytes == 0 || titleBytes > MAX_TITLE_BYTES) revert TitleLength();
    if (bytes(metadataURI).length > MAX_URI_BYTES) revert UriLength();
    if (kind == KIND_GOAL) {
      if (goal == 0 || goal > MAX_AMOUNT) revert BadGoal();
      if (deadline <= block.timestamp) revert BadDeadline();
      uint256 duration = uint256(deadline) - block.timestamp;
      if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDeadline();
    } else {
      if (goal != 0) revert BadGoal();
      if (deadline != 0) revert BadDeadline();
    }

    id = nextId++;
    _campaigns[id] = Campaign({
      beneficiary: beneficiary,
      asset: asset,
      kind: kind,
      deadline: deadline,
      goal: goal,
      creator: creator,
      title: title,
      metadataURI: metadataURI
    });
  }
}

interface IGiveEscrowView {
  function registry() external view returns (address);
  function usdt() external view returns (address);
}
