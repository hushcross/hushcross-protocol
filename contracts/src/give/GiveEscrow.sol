// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {Constants} from 'contracts/lib/Constants.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {GiveMath} from './GiveMath.sol';
import {GiveRegistry} from './GiveRegistry.sol';
import {GiveTypes} from './GiveTypes.sol';

/// @title GiveEscrow
/// @notice Holds goal funds, pays tips immediately, and emits every event the indexer reads.
/// @dev Deadline rule: donations are open while `block.timestamp < deadline`. Settlement opens at
///      `block.timestamp >= deadline`. A goal is reached when the total is greater than or equal to the goal.
///      Only donations that arrived through GiveAdapter may be refunded into the vault. A public donation
///      refunds the full amount to the address registered with it.
///      Vault refunds split the amount into at most 16 pool units. Each note's gross is the vetting-fee
///      inverse of that unit, read from the Entrypoint at refund time. Dust goes to the donor's dust address.
///      A deposit that reverts with reason data becomes dust. A revert with no data aborts the refund.
contract GiveEscrow is ReentrancyGuard {
  using SafeERC20 for IERC20;

  uint256 internal constant MAX_NOTES = 16;

  struct Funds {
    uint256 total;
    uint256 escrowed;
    uint256 donations;
    bool settled;
    bool reached;
    bool released;
  }

  struct Donation {
    uint256 amount;
    bytes32 receiptHash;
    address payout;
    bool vaultFunded;
    bool refunded;
  }

  GiveRegistry public immutable registry;
  IEntrypoint public immutable entrypoint;
  address public immutable usdt;
  address public adapter;

  mapping(uint256 id => Funds) private _funds;
  mapping(uint256 id => mapping(uint256 index => Donation)) private _donations;
  mapping(uint256 id => mapping(uint256 index => uint256[])) private _notes;
  mapping(uint256 id => mapping(bytes32 receiptHash => uint256)) private _receipts;
  mapping(uint256 precommitment => bool) private _reserved;
  mapping(address asset => uint256) public accounted;

  address private _deployer;

  event CampaignCreated(
    uint256 indexed campaignId, address indexed beneficiary, uint8 kind, address asset, uint256 goal, uint64 deadline
  );
  event Donated(uint256 indexed campaignId, uint256 amount, bytes32 receiptHash);
  event CampaignSettled(uint256 indexed campaignId, bool reached, uint256 total);
  event FundsReleased(uint256 indexed campaignId, uint256 amount);
  event Refunded(uint256 indexed campaignId, uint256 amount);
  event VaultNoteOpened(
    uint256 indexed campaignId, uint256 indexed donationIndex, uint256 precommitment, uint256 gross, uint256 net
  );
  event VaultNoteSkipped(
    uint256 indexed campaignId, uint256 indexed donationIndex, uint256 precommitment, uint256 gross
  );

  error InvalidConfig();
  error NotDeployer();
  error AlreadyLinked();
  error NotAdapter();
  error AssetUnregistered();
  error BadBeneficiary();
  error AmountOutOfRange();
  error NativeValue();
  error Closed();
  error TooEarly();
  error NotGoal();
  error AlreadySettled();
  error NotReleasable();
  error NotRefundable();
  error AlreadyRefunded();
  error UnknownDonation();
  error RefundAddress();
  error DustRecipient();
  error NoteCount();
  error InvalidPrecommitment();
  error DuplicatePrecommitment();
  error PrecommitmentUsed();
  error DepositStarved();
  error TransferFailed();
  error Accounting();

  constructor(address registry_, address entrypoint_, address usdt_) {
    if (registry_.code.length == 0 || entrypoint_.code.length == 0 || usdt_.code.length == 0) revert InvalidConfig();
    if (GiveRegistry(registry_).usdt() != usdt_) revert InvalidConfig();
    registry = GiveRegistry(registry_);
    entrypoint = IEntrypoint(entrypoint_);
    usdt = usdt_;
    _deployer = msg.sender;
  }

  function linkAdapter(address adapter_) external {
    if (msg.sender != _deployer) revert NotDeployer();
    if (adapter != address(0)) revert AlreadyLinked();
    if (adapter_.code.length == 0) revert InvalidConfig();
    if (IGiveAdapterView(adapter_).escrow() != address(this)) revert InvalidConfig();
    if (IGiveAdapterView(adapter_).entrypoint() != address(entrypoint)) revert InvalidConfig();
    adapter = adapter_;
    _deployer = address(0);
  }

  function funds(uint256 id) external view returns (Funds memory) {
    return _funds[id];
  }

  function donation(uint256 id, uint256 index) external view returns (Donation memory) {
    return _donations[id][index];
  }

  function donationNotes(uint256 id, uint256 index) external view returns (uint256[] memory) {
    return _notes[id][index];
  }

  function receiptTotal(uint256 id, bytes32 receiptHash) external view returns (uint256) {
    return _receipts[id][receiptHash];
  }

  /// @notice Cumulative donated amount whose receipt hash is `keccak256(secret)`.
  function verifyReceipt(bytes calldata secret, uint256 id) external view returns (uint256) {
    return _receipts[id][keccak256(secret)];
  }

  function createCampaign(
    uint8 kind,
    address asset,
    address beneficiary,
    uint256 goal,
    uint64 deadline,
    string calldata title,
    string calldata metadataURI
  ) external nonReentrant returns (uint256 id) {
    if (beneficiary == address(this) || beneficiary == adapter) revert BadBeneficiary();
    id = registry.create(msg.sender, kind, asset, beneficiary, goal, deadline, title, metadataURI);
    _assertPool(asset);
    emit CampaignCreated(id, beneficiary, kind, asset, goal, deadline);
  }

  function donate(uint256 id, uint256 amount, bytes32 receiptHash, address refundTo) external payable nonReentrant {
    GiveRegistry.Campaign memory campaign = registry.campaign(id);
    _collect(campaign.asset, amount);
    _record(campaign, id, amount, receiptHash, false, refundTo, new uint256[](0));
  }

  function donateFromAdapter(
    uint256 id,
    uint256 amount,
    bytes32 receiptHash,
    address dustRecipient,
    uint256[] memory precommitments
  ) external payable nonReentrant {
    if (msg.sender != adapter) revert NotAdapter();
    GiveRegistry.Campaign memory campaign = registry.campaign(id);
    _collect(campaign.asset, amount);
    _record(campaign, id, amount, receiptHash, true, dustRecipient, precommitments);
  }

  function settle(uint256 id) external nonReentrant {
    GiveRegistry.Campaign memory campaign = registry.campaign(id);
    if (campaign.kind != GiveTypes.KIND_GOAL) revert NotGoal();
    if (block.timestamp < campaign.deadline) revert TooEarly();
    Funds storage state = _funds[id];
    if (state.settled) revert AlreadySettled();
    state.settled = true;
    state.reached = state.total >= campaign.goal;
    emit CampaignSettled(id, state.reached, state.total);
  }

  function release(uint256 id) external nonReentrant {
    GiveRegistry.Campaign memory campaign = registry.campaign(id);
    if (campaign.kind != GiveTypes.KIND_GOAL) revert NotGoal();
    Funds storage state = _funds[id];
    if (!state.settled || !state.reached || state.released) revert NotReleasable();
    uint256 amount = state.escrowed;
    if (amount != state.total) revert Accounting();
    state.released = true;
    state.escrowed = 0;
    accounted[campaign.asset] -= amount;
    emit FundsReleased(id, amount);
    _push(campaign.asset, campaign.beneficiary, amount);
  }

  function refund(uint256 id, uint256 index) external nonReentrant {
    GiveRegistry.Campaign memory campaign = registry.campaign(id);
    if (campaign.kind != GiveTypes.KIND_GOAL) revert NotGoal();
    Funds storage state = _funds[id];
    if (!state.settled || state.reached) revert NotRefundable();
    if (index >= state.donations) revert UnknownDonation();
    Donation storage gift = _donations[id][index];
    if (gift.refunded) revert AlreadyRefunded();
    uint256 amount = gift.amount;
    address payout = gift.payout;
    bool vault = gift.vaultFunded;
    gift.refunded = true;
    state.escrowed -= amount;
    accounted[campaign.asset] -= amount;
    emit Refunded(id, amount);
    if (vault) _refundVault(id, index, campaign.asset, amount, payout);
    else _push(campaign.asset, payout, amount);
  }

  function _record(
    GiveRegistry.Campaign memory campaign,
    uint256 id,
    uint256 amount,
    bytes32 receiptHash,
    bool fromAdapter,
    address payout,
    uint256[] memory notes
  ) internal {
    bool goal = campaign.kind == GiveTypes.KIND_GOAL;
    if (goal) {
      if (block.timestamp >= campaign.deadline) revert Closed();
      if (fromAdapter) {
        _reserve(notes);
        if (!_canReceive(payout)) revert DustRecipient();
      } else {
        if (notes.length != 0) revert NoteCount();
        if (!_canReceive(payout)) revert RefundAddress();
      }
    } else if (notes.length != 0) {
      revert NoteCount();
    }

    Funds storage state = _funds[id];
    uint256 index = state.donations;
    state.donations = index + 1;
    state.total += amount;
    bool vault = fromAdapter && goal;
    if (goal) {
      state.escrowed += amount;
      accounted[campaign.asset] += amount;
    }
    _donations[id][index] = Donation({
      amount: amount, receiptHash: receiptHash, payout: goal ? payout : address(0), vaultFunded: vault, refunded: false
    });
    if (vault) {
      uint256 n = notes.length;
      for (uint256 i; i < n; ++i) {
        _notes[id][index].push(notes[i]);
      }
    }
    if (receiptHash != bytes32(0)) _receipts[id][receiptHash] += amount;
    emit Donated(id, amount, receiptHash);
    if (!goal) _push(campaign.asset, campaign.beneficiary, amount);
  }

  function _reserve(uint256[] memory notes) internal {
    uint256 n = notes.length;
    if (n == 0 || n > MAX_NOTES) revert NoteCount();
    for (uint256 i; i < n; ++i) {
      uint256 pc = notes[i];
      if (pc == 0 || pc >= Constants.SNARK_SCALAR_FIELD) revert InvalidPrecommitment();
      if (_reserved[pc] || entrypoint.usedPrecommitments(pc)) revert PrecommitmentUsed();
      for (uint256 j = i + 1; j < n; ++j) {
        if (notes[j] == pc) revert DuplicatePrecommitment();
      }
    }
    for (uint256 i; i < n; ++i) {
      _reserved[notes[i]] = true;
    }
  }

  function _refundVault(uint256 id, uint256 index, address asset, uint256 amount, address dustTo) internal {
    (bool live, uint256 minimum, uint256 feeBps) = _fee(asset);
    if (!live) {
      _push(asset, dustTo, amount);
      return;
    }
    uint256 paid = _openNotes(id, index, asset, amount, feeBps, minimum);
    _push(asset, dustTo, amount - paid);
  }

  function _openNotes(
    uint256 id,
    uint256 index,
    address asset,
    uint256 amount,
    uint256 feeBps,
    uint256 minimum
  ) internal returns (uint256 paid) {
    uint256[] memory notes = _notes[id][index];
    (uint256 count, uint256[16] memory grosses, uint256[16] memory nets) =
      _plan(asset, amount, feeBps, notes.length, minimum);
    for (uint256 i; i < count; ++i) {
      if (_depositOne(asset, id, index, notes[i], grosses[i], nets[i])) paid += grosses[i];
    }
  }

  function _plan(
    address asset,
    uint256 amount,
    uint256 feeBps,
    uint256 maxNotes,
    uint256 minimum
  ) internal pure returns (uint256 count, uint256[16] memory grosses, uint256[16] memory nets) {
    uint256[5] memory units = asset == address(0) ? GiveMath.bnbUnits() : GiveMath.usdtUnits();
    (count, grosses, nets,) = GiveMath.allocate(amount, feeBps, units, maxNotes, minimum);
  }

  function _depositOne(
    address asset,
    uint256 id,
    uint256 index,
    uint256 precommitment,
    uint256 gross,
    uint256 net
  ) internal returns (bool opened) {
    if (asset == address(0)) return _depositNative(id, index, precommitment, gross, net);
    return _depositToken(asset, id, index, precommitment, gross, net);
  }

  function _depositNative(
    uint256 id,
    uint256 index,
    uint256 precommitment,
    uint256 gross,
    uint256 net
  ) internal returns (bool opened) {
    try entrypoint.deposit{value: gross}(precommitment) returns (uint256) {
      emit VaultNoteOpened(id, index, precommitment, gross, net);
      return true;
    } catch (bytes memory reason) {
      if (reason.length == 0) revert DepositStarved();
    }
    emit VaultNoteSkipped(id, index, precommitment, gross);
    return false;
  }

  function _depositToken(
    address asset,
    uint256 id,
    uint256 index,
    uint256 precommitment,
    uint256 gross,
    uint256 net
  ) internal returns (bool opened) {
    IERC20 token = IERC20(asset);
    token.forceApprove(address(entrypoint), gross);
    try entrypoint.deposit(token, gross, precommitment) returns (uint256) {
      token.forceApprove(address(entrypoint), 0);
      emit VaultNoteOpened(id, index, precommitment, gross, net);
      return true;
    } catch (bytes memory reason) {
      token.forceApprove(address(entrypoint), 0);
      if (reason.length == 0) revert DepositStarved();
    }
    emit VaultNoteSkipped(id, index, precommitment, gross);
    return false;
  }

  function _collect(address asset, uint256 amount) internal {
    if (amount == 0 || amount > GiveTypes.MAX_AMOUNT) revert AmountOutOfRange();
    if (asset == address(0)) {
      if (msg.value != amount) revert NativeValue();
    } else {
      if (msg.value != 0) revert NativeValue();
      IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }
  }

  function _push(address asset, address to, uint256 amount) internal {
    if (amount == 0) return;
    if (to == address(0)) revert TransferFailed();
    if (asset == address(0)) {
      (bool ok, bytes memory reason) = to.call{value: amount}('');
      if (ok) return;
      if (reason.length == 0) revert TransferFailed();
      assembly {
        revert(add(reason, 32), mload(reason))
      }
    } else {
      IERC20(asset).safeTransfer(to, amount);
    }
  }

  function _assertPool(address asset) internal view {
    (bool live,,) = _fee(asset);
    if (!live) revert AssetUnregistered();
  }

  function _fee(address asset) internal view returns (bool live, uint256 minimum, uint256 feeBps) {
    address vaultAsset = asset == address(0) ? Constants.NATIVE_ASSET : asset;
    (IPrivacyPool pool, uint256 min, uint256 fee,) = entrypoint.assetConfig(IERC20(vaultAsset));
    live = address(pool) != address(0) && fee < GiveMath.BPS;
    return (live, min, fee);
  }

  function _canReceive(address account) internal view returns (bool) {
    return account != address(0) && account != address(this) && account != adapter;
  }
}

interface IGiveAdapterView {
  function escrow() external view returns (address);
  function entrypoint() external view returns (address);
}
