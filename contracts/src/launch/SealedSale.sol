// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LaunchClearing} from './LaunchClearing.sol';
import {LaunchConstants, SaleConfig} from './LaunchTypes.sol';
import {INonfungiblePositionManager} from './interfaces/IPancakeV3.sol';
import {BidHeap} from './sale/BidHeap.sol';
import {LiquiditySeeder} from './sale/LiquiditySeeder.sol';
import {QuoteTransfers} from './sale/QuoteTransfers.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

interface ILaunchHooks {
  function launchAdapter() external view returns (address);
}

/// @title SealedSale
/// @notice Commit / reveal uniform-price token sale (docs/modules/launch.md) with permissionless O(n)
///         finalisation, vault-aware refunds and PancakeSwap V3 liquidity at p* (LP NFT locked forever;
///         trading fees are collectable).
contract SealedSale is ReentrancyGuard, QuoteTransfers, LiquiditySeeder {
  using SafeERC20 for IERC20;
  using BidHeap for uint256[];

  enum BidStatus {
    None,
    Committed,
    Evicted,
    Revealed,
    Claimed
  }

  enum Outcome {
    Pending,
    Cleared,
    Failed
  }

  /// @dev Validity codes, LAUNCH.md section 4.2 (checked in this order).
  uint8 public constant VALID = 0;
  uint8 public constant PRICE_BELOW_FLOOR = 1;
  uint8 public constant ESCROW_BELOW_MINIMUM = 2;
  uint8 public constant MAX_SPEND_EXCEEDS_ESCROW = 3;
  uint8 public constant ZERO_QUANTITY = 4;

  struct Bid {
    uint128 escrow;
    /// @dev Full width: demand revealed earlier at the same price, never truncated.
    uint256 prefix;
    address recipient;
    uint32 entry;
    uint32 bidId;
    BidStatus status;
    /// @dev True only when `commit` was called by the registered LaunchAdapter.
    bool vaultFunded;
    bytes32 refundsHash;
  }

  uint256 public immutable saleId;
  address public immutable factory;
  address public immutable creator;
  IERC20 public immutable token;
  address public immutable treasury;
  uint256 public immutable saleSupply;
  uint256 public immutable lpTokenReserve;
  uint256 public immutable floorPrice;
  uint256 public immutable minRaise;
  uint256 public immutable minEscrow;
  uint64 public immutable commitEnd;
  uint64 public immutable revealEnd;
  uint16 public immutable liquidityBps;
  uint32 public immutable maxBids;

  uint256[5] internal _units;
  uint256 public bidCount;
  uint256 public totalEscrow;
  mapping(bytes32 commitment => Bid) internal _bids;
  mapping(uint256 bidId => bytes32) public commitmentOf;
  mapping(uint256 price => uint256) public levelDemand;
  uint256[] internal _heap;
  uint256[] internal _entries;
  /// @dev Payer of each public (non-vault) bid, so a displaced copy can be refunded.
  mapping(bytes32 commitment => address) internal _payer;
  /// @dev Heap keys left behind by displaced bids; skipped (and dropped) when they reach the top.
  uint256 internal _staleKeys;

  Outcome public outcome;
  uint64 public finalizedAt;
  LaunchClearing.Result internal _result;
  LaunchClearing.Liquidity internal _liquidity;
  uint256 public raise;
  uint256 public fee;
  uint256 public tokensBurned;
  uint256 public creatorProceeds;

  error CommitClosed();
  error NotRevealPhase();
  error NotFinalizePhase();
  error AbortTooEarly();
  error AlreadyFinalized();
  error NotFinalized();
  error InvalidCommitment();
  error InvalidEscrow();
  error EscrowTooLow();
  error UnknownCommitment();
  error InvalidBidStatus();
  error RefundsMismatch();
  error MalformedReveal();
  error NotAuthorized();
  error UnexpectedNative();
  error NoPosition();
  error FeeSaleMismatch();

  /// @dev Indexer events (services/indexer HushCrossIndexedEvents): exact signatures.
  event BidCommitted(uint256 indexed saleId, bytes32 indexed commitment, uint256 escrow);
  event BidRevealed(uint256 indexed saleId, bytes32 indexed commitment);
  event SaleCleared(uint256 indexed saleId, uint256 clearingPrice, uint256 tokensSold, uint256 raise);
  event SaleFailed(uint256 indexed saleId, uint256 totalEscrow);
  event LiquidityAdded(
    uint256 indexed saleId, address indexed pool, uint256 positionId, uint256 tokenAmount, uint256 quoteAmount
  );
  /// @dev Additional events.
  event BidEvicted(bytes32 indexed commitment, uint256 escrow);
  /// @dev A vault-funded commit took over a public, unrevealed copy of its commitment; `escrow` went back to `payer`.
  event BidDisplaced(uint256 indexed saleId, bytes32 indexed commitment, address payer, uint256 escrow);
  event BidValidity(bytes32 indexed commitment, uint8 reason, uint256 quantity);
  event BidClaimed(
    bytes32 indexed commitment, uint256 tokens, uint256 spend, uint256 refund, uint256 notes, uint256 dust
  );
  event CreatorProceedsClaimed(uint256 amount);
  /// @dev Trading fees taken from the locked position. Each token is split half / half.
  event FeesCollected(uint256 indexed saleId, address token0, address token1, uint256 amount0, uint256 amount1);

  constructor(SaleConfig memory c)
    QuoteTransfers(c.quoteAsset, c.wbnb, c.entrypoint)
    LiquiditySeeder(c.positionManager, c.pancakeFactory)
  {
    saleId = c.saleId;
    factory = c.factory;
    creator = c.creator;
    token = IERC20(c.token);
    treasury = c.treasury;
    saleSupply = c.saleSupply;
    lpTokenReserve = c.lpTokenReserve;
    floorPrice = c.floorPrice;
    minRaise = c.minRaise;
    minEscrow = c.minEscrow;
    commitEnd = c.commitEnd;
    revealEnd = c.revealEnd;
    liquidityBps = c.liquidityBps;
    maxBids = c.maxBids;
    _units = c.units;
  }

  /// @dev Only WBNB unwraps may send native value outside of `commit`.
  receive() external payable {
    if (msg.sender != address(wbnb)) revert UnexpectedNative();
  }

  // ------------------------------------------------------------------ commit / reveal

  /// @notice Escrow `amount` of the quote asset behind a sealed bid commitment (LAUNCH.md section 3).
  /// @dev With `maxBids` live bids, the new escrow must strictly exceed the smallest one, which is evicted
  ///      (ties: the most recent of the smallest). Evicted escrow is reclaimed by `lateReveal`.
  ///      a LaunchAdapter commit displaces a public, unrevealed (committed or evicted) copy of its
  ///      commitment; that copy's escrow goes back to its payer in this call and the copy can never be revealed.
  function commit(bytes32 commitment, uint256 amount) external payable nonReentrant returns (uint256 bidId) {
    if (block.timestamp >= commitEnd) revert CommitClosed();
    if (commitment == bytes32(0)) revert InvalidCommitment();
    bool vaultFunded = _isLaunchAdapter(msg.sender);
    uint256 floor = vaultFunded ? privateMinEscrow() : minEscrow;
    if (amount < floor || amount > LaunchConstants.MAX_AMOUNT) revert InvalidEscrow();
    Bid storage bid = _bids[commitment];
    address displacedPayer;
    uint256 displacedEscrow;
    if (bid.status != BidStatus.None) {
      if (!vaultFunded || bid.vaultFunded || (bid.status != BidStatus.Committed && bid.status != BidStatus.Evicted)) {
        revert InvalidCommitment();
      }
      (displacedPayer, displacedEscrow) = _displace(commitment, bid);
    }
    bidId = ++bidCount;
    if (_heap.length - _staleKeys >= maxBids) _evictMin(amount);
    bid.escrow = uint128(amount);
    bid.bidId = uint32(bidId);
    bid.status = BidStatus.Committed;
    bid.vaultFunded = vaultFunded;
    commitmentOf[bidId] = commitment;
    totalEscrow += amount;
    _heap.insert(BidHeap.key(amount, bidId));
    if (!vaultFunded) _payer[commitment] = msg.sender;
    emit BidCommitted(saleId, commitment, amount);
    _pullQuote(msg.sender, amount);
    if (displacedPayer != address(0)) _refundDisplaced(displacedPayer, displacedEscrow);
  }

  /// @dev Pops stale keys of displaced bids, then evicts the smallest live bid.
  function _evictMin(uint256 amount) private {
    uint256 minKey = _heap.popMin();
    bytes32 evicted = commitmentOf[BidHeap.bidIdOf(minKey)];
    while (evicted == bytes32(0)) {
      _staleKeys -= 1;
      minKey = _heap.popMin();
      evicted = commitmentOf[BidHeap.bidIdOf(minKey)];
    }
    uint256 evictedEscrow = BidHeap.escrowOf(minKey);
    if (amount <= evictedEscrow) revert EscrowTooLow();
    _bids[evicted].status = BidStatus.Evicted;
    emit BidEvicted(evicted, evictedEscrow);
  }

  /// @dev The caller overwrites the record. A committed copy's heap key becomes stale (its id maps to nothing).
  function _displace(bytes32 commitment, Bid storage bid) private returns (address payer, uint256 escrow) {
    payer = _payer[commitment];
    escrow = bid.escrow;
    if (bid.status == BidStatus.Committed) _staleKeys += 1;
    delete commitmentOf[bid.bidId];
    delete _payer[commitment];
    totalEscrow -= escrow;
    emit BidDisplaced(saleId, commitment, payer, escrow);
  }

  /// @dev No receive hook can run: native escrow is returned as WBNB, so the payer cannot block or grief the call.
  function _refundDisplaced(address payer, uint256 escrow) private {
    if (_isNative()) {
      wbnb.deposit{value: escrow}();
      IERC20(address(wbnb)).safeTransfer(payer, escrow);
    } else {
      IERC20(quoteAsset).safeTransfer(payer, escrow);
    }
  }

  /// @notice Open a sealed bid during the reveal window; anyone holding the preimage may call.
  /// @dev Structural failures revert (LAUNCH.md 4.1); economic failures record the bid as revealed-invalid.
  function reveal(
    uint256 price,
    uint256 maxSpend,
    address recipient,
    uint256[] calldata precommitments,
    bytes32 salt
  ) external nonReentrant returns (bytes32 commitment) {
    if (block.timestamp < commitEnd || block.timestamp >= revealEnd) revert NotRevealPhase();
    bytes32 refundsHash = _checkStructure(price, maxSpend, recipient, precommitments);
    commitment = computeCommitment(price, maxSpend, recipient, refundsHash, salt);
    Bid storage bid = _bids[commitment];
    if (bid.status == BidStatus.None) revert UnknownCommitment();
    if (bid.status != BidStatus.Committed) revert InvalidBidStatus();
    bid.status = BidStatus.Revealed;
    bid.recipient = recipient;
    bid.refundsHash = refundsHash;
    (uint8 reason, uint256 qty) = _validity(price, maxSpend, bid.escrow, _escrowFloor(bid.vaultFunded));
    if (reason == VALID) {
      if (qty > LaunchConstants.MAX_AMOUNT) revert MalformedReveal();
      uint256 prefix = levelDemand[price];
      levelDemand[price] = prefix + qty;
      bid.prefix = prefix;
      _entries.push(LaunchClearing.pack(price, qty));
      bid.entry = uint32(_entries.length);
    }
    emit BidRevealed(saleId, commitment);
    emit BidValidity(commitment, reason, qty);
  }

  /// @notice Economic validity in LAUNCH.md order against the public one-unit floor.
  function validity(uint256 price, uint256 maxSpend, uint256 escrow) public view returns (uint8, uint256) {
    return _validity(price, maxSpend, escrow, minEscrow);
  }

  /// @dev Vault-funded bids use `privateMinEscrow` so one minimum-unit note can clear the relay-fee cap.
  function _validity(
    uint256 price,
    uint256 maxSpend,
    uint256 escrow,
    uint256 floor
  ) internal view returns (uint8, uint256) {
    if (price < floorPrice) return (PRICE_BELOW_FLOOR, 0);
    if (escrow < floor) return (ESCROW_BELOW_MINIMUM, 0);
    if (maxSpend > escrow) return (MAX_SPEND_EXCEEDS_ESCROW, 0);
    uint256 qty = LaunchClearing.quantity(maxSpend, price);
    if (qty == 0) return (ZERO_QUANTITY, 0);
    return (VALID, qty);
  }

  function _escrowFloor(bool vaultFunded) internal view returns (uint256) {
    return vaultFunded ? privateMinEscrow() : minEscrow;
  }

  function _isLaunchAdapter(address caller) internal view returns (bool) {
    address adapter = ILaunchHooks(factory).launchAdapter();
    return adapter != address(0) && caller == adapter;
  }

  function _checkStructure(
    uint256 price,
    uint256 maxSpend,
    address recipient,
    uint256[] calldata pcs
  ) private pure returns (bytes32) {
    if (price > LaunchConstants.MAX_AMOUNT || maxSpend > LaunchConstants.MAX_AMOUNT || recipient == address(0)) {
      revert MalformedReveal();
    }
    uint256 n = pcs.length;
    if (n > LaunchConstants.MAX_REFUND_NOTES) revert MalformedReveal();
    for (uint256 i; i < n; ++i) {
      if (pcs[i] == 0 || pcs[i] >= LaunchConstants.SNARK_SCALAR_FIELD) revert MalformedReveal();
    }
    return keccak256(abi.encodePacked(pcs));
  }

  // ------------------------------------------------------------------ finalisation

  /// @notice Permissionless finalisation at a proposed clearing price, verified on-chain in O(n).
  function finalize(uint256 clearingPrice) external nonReentrant {
    if (block.timestamp < revealEnd) revert NotFinalizePhase();
    if (outcome != Outcome.Pending) revert AlreadyFinalized();
    LaunchClearing.Result memory r = LaunchClearing.verify(_entries, saleSupply, floorPrice, clearingPrice);
    finalizedAt = uint64(block.timestamp);
    if (r.attemptedRaise == 0 || r.attemptedRaise < minRaise) {
      r.tokensSold = 0;
      _result = r;
      _fail();
      return;
    }
    _result = r;
    outcome = Outcome.Cleared;
    uint256 raised = r.attemptedRaise;
    uint256 protocolFee = (raised * LaunchConstants.FEE_BPS) / LaunchConstants.BPS;
    uint256 netRaise = raised - protocolFee;
    LaunchClearing.Liquidity memory l = LaunchClearing.liquidity(netRaise, liquidityBps, lpTokenReserve, clearingPrice);
    raise = raised;
    fee = protocolFee;
    _liquidity = l;
    uint256 burn = saleSupply - r.tokensSold + (lpTokenReserve - l.token);
    uint256 proceeds = netRaise - l.quote;
    if (l.token != 0) {
      SeedOutcome memory o = _seed(l, clearingPrice);
      burn += o.tokenLeft;
      proceeds += o.quoteLeft;
      emit LiquidityAdded(saleId, lpPool, lpTokenId, o.tokenUsed, o.quoteUsed);
    }
    tokensBurned = burn;
    creatorProceeds = proceeds;
    if (burn != 0) token.safeTransfer(LaunchConstants.BURN_ADDRESS, burn);
    _sendQuote(treasury, protocolFee);
    emit SaleCleared(saleId, clearingPrice, r.tokensSold, raised);
  }

  /// @notice Safety valve: if nobody finalised within SETTLE_GRACE after the reveal window, the sale fails.
  function abort() external nonReentrant {
    if (outcome != Outcome.Pending) revert AlreadyFinalized();
    if (block.timestamp < uint256(revealEnd) + LaunchConstants.SETTLE_GRACE) revert AbortTooEarly();
    finalizedAt = uint64(block.timestamp);
    _fail();
  }

  function _fail() private {
    outcome = Outcome.Failed;
    token.safeTransfer(creator, saleSupply + lpTokenReserve);
    emit SaleFailed(saleId, totalEscrow);
  }

  function _seed(LaunchClearing.Liquidity memory l, uint256 clearingPrice) private returns (SeedOutcome memory o) {
    address quoteToken = quoteAsset;
    if (_isNative()) {
      quoteToken = address(wbnb);
      wbnb.deposit{value: l.quote}();
    }
    o = _seedLiquidity(address(token), quoteToken, l.token, l.quote, clearingPrice);
    if (_isNative() && o.quoteLeft != 0) wbnb.withdraw(o.quoteLeft);
  }

  // ------------------------------------------------------------------ claims

  /// @notice Deliver tokens to the recipient and return unspent escrow as vault notes plus dust.
  function claim(bytes32 commitment, uint256[] calldata precommitments) external nonReentrant {
    if (outcome == Outcome.Pending) revert NotFinalized();
    Bid storage bid = _bids[commitment];
    if (bid.status != BidStatus.Revealed) revert InvalidBidStatus();
    if (keccak256(abi.encodePacked(precommitments)) != bid.refundsHash) revert RefundsMismatch();
    (uint256 tokens, uint256 paid) = _allocationOf(bid);
    bool vaultFunded = bid.vaultFunded;
    bid.status = BidStatus.Claimed;
    _settleBid(commitment, bid.recipient, tokens, paid, bid.escrow, precommitments, vaultFunded);
  }

  /// @notice Escape hatch for the recipient: tokens plus the whole refund directly, skipping the vault.
  function claimToPayout(bytes32 commitment) external nonReentrant {
    if (outcome == Outcome.Pending) revert NotFinalized();
    Bid storage bid = _bids[commitment];
    if (bid.status != BidStatus.Revealed) revert InvalidBidStatus();
    address recipient = bid.recipient;
    if (msg.sender != recipient) revert NotAuthorized();
    (uint256 tokens, uint256 paid) = _allocationOf(bid);
    bid.status = BidStatus.Claimed;
    uint256 refund = bid.escrow - paid;
    if (tokens != 0) token.safeTransfer(recipient, tokens);
    _sendQuote(recipient, refund);
    emit BidClaimed(commitment, tokens, paid, refund, 0, refund);
  }

  /// @notice Late reveal (LAUNCH.md 4.4): after finalisation an unrevealed or evicted bid gets its full escrow.
  function lateReveal(
    uint256 price,
    uint256 maxSpend,
    address recipient,
    uint256[] calldata precommitments,
    bytes32 salt
  ) external nonReentrant returns (bytes32 commitment) {
    if (outcome == Outcome.Pending) revert NotFinalized();
    bytes32 refundsHash = _checkStructure(price, maxSpend, recipient, precommitments);
    commitment = computeCommitment(price, maxSpend, recipient, refundsHash, salt);
    Bid storage bid = _bids[commitment];
    if (bid.status == BidStatus.None) revert UnknownCommitment();
    if (bid.status != BidStatus.Committed && bid.status != BidStatus.Evicted) revert InvalidBidStatus();
    bool vaultFunded = bid.vaultFunded;
    bid.status = BidStatus.Claimed;
    bid.recipient = recipient;
    bid.refundsHash = refundsHash;
    emit BidRevealed(saleId, commitment);
    _settleBid(commitment, recipient, 0, 0, bid.escrow, precommitments, vaultFunded);
  }

  function _settleBid(
    bytes32 commitment,
    address recipient,
    uint256 tokens,
    uint256 paid,
    uint256 escrow,
    uint256[] calldata precommitments,
    bool vaultFunded
  ) private {
    uint256 refund = escrow - paid;
    if (tokens != 0) token.safeTransfer(recipient, tokens);
    uint256 dust = refund;
    uint256 notes;
    // Public-wallet bids never re-enter the vault, even when the commitment lists precommitments.
    if (vaultFunded) (dust, notes) = _refundToVault(refund, precommitments, _units);
    _sendQuote(recipient, dust);
    emit BidClaimed(commitment, tokens, paid, refund, notes, dust);
  }

  /// @notice Collect trading fees from the locked LP. Anyone may call. Half of each token goes to
  ///         the creator and half to `treasury` (the odd unit goes to the treasury). Liquidity stays put.
  function collectFees(uint256 saleId_) external nonReentrant {
    if (saleId_ != saleId) revert FeeSaleMismatch();
    if (lpTokenId == 0) revert NoPosition();
    (,, address token0, address token1,,,,,,,,) = positionManager.positions(lpTokenId);
    (uint256 amount0, uint256 amount1) = positionManager.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: lpTokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
      })
    );
    _splitFee(token0, amount0);
    _splitFee(token1, amount1);
    emit FeesCollected(saleId, token0, token1, amount0, amount1);
  }

  /// @dev Remainder of an odd amount goes to the treasury so the sale keeps none of the fee.
  function _splitFee(address feeToken, uint256 amount) private {
    if (amount == 0) return;
    uint256 toCreator = amount / 2;
    IERC20(feeToken).safeTransfer(creator, toCreator);
    IERC20(feeToken).safeTransfer(treasury, amount - toCreator);
  }

  function _allocationOf(Bid storage bid) private view returns (uint256 tokens, uint256 paid) {
    if (outcome != Outcome.Cleared || bid.entry == 0) return (0, 0);
    (uint256 price, uint256 qty) = LaunchClearing.unpack(_entries[bid.entry - 1]);
    LaunchClearing.Result memory r = _result;
    tokens = LaunchClearing.fillOf(price, qty, bid.prefix, r);
    paid = LaunchClearing.spend(tokens, r.clearingPrice);
  }

  function claimProceeds() external nonReentrant returns (uint256 amount) {
    if (msg.sender != creator) revert NotAuthorized();
    amount = creatorProceeds;
    creatorProceeds = 0;
    _sendQuote(creator, amount);
    emit CreatorProceedsClaimed(amount);
  }

  // ------------------------------------------------------------------ views

  /// @notice LAUNCH.md section 2 commitment; `refundsHash` = keccak256(abi.encodePacked(precommitments)).
  function computeCommitment(
    uint256 price,
    uint256 maxSpend,
    address recipient,
    bytes32 refundsHash,
    bytes32 salt
  ) public view returns (bytes32) {
    return keccak256(
      abi.encode(
        LaunchConstants.LAUNCH_BID_TAG,
        block.chainid,
        address(this),
        saleId,
        price,
        maxSpend,
        recipient,
        refundsHash,
        salt
      )
    );
  }

  /// @notice Dry-run of `finalize` verification; reverts with the LAUNCH.md reason for a wrong price.
  function previewFinalize(uint256 clearingPrice) external view returns (LaunchClearing.Result memory) {
    return LaunchClearing.verify(_entries, saleSupply, floorPrice, clearingPrice);
  }

  function bidInfo(bytes32 commitment) external view returns (Bid memory) {
    return _bids[commitment];
  }

  function allocationOf(bytes32 commitment) external view returns (uint256 tokens, uint256 paid) {
    return _allocationOf(_bids[commitment]);
  }

  function clearingResult() external view returns (LaunchClearing.Result memory) {
    return _result;
  }

  function liquidityPlan() external view returns (LaunchClearing.Liquidity memory) {
    return _liquidity;
  }

  function entryCount() external view returns (uint256) {
    return _entries.length;
  }

  function entryAt(uint256 index) external view returns (uint256 price, uint256 qty) {
    return LaunchClearing.unpack(_entries[index]);
  }

  function liveBidCount() external view returns (uint256) {
    return _heap.length - _staleKeys;
  }

  /// @dev A lower bound after a displacement: a stale key can sit at the top until the next eviction drops it.
  function minLiveEscrow() external view returns (uint256) {
    return _heap.length == 0 ? 0 : BidHeap.escrowOf(_heap[0]);
  }

  function units() external view returns (uint256[5] memory) {
    return _units;
  }

  /// @notice Smallest escrow a LaunchAdapter bid may post: one minimum unit times `(1 - maxRelayFeeBPS)`.
  /// @dev Read from the pool configuration at call time. A one-unit withdrawal at the fee cap leaves exactly this.
  function privateMinEscrow() public view returns (uint256) {
    (,,, uint256 maxRelayFeeBPS) = entrypoint.assetConfig(_vaultAsset());
    return (minEscrow * (LaunchConstants.BPS - maxRelayFeeBPS)) / LaunchConstants.BPS;
  }
}
