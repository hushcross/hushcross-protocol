// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWBNB} from '../launch/interfaces/IWBNB.sol';
import {BookClearing} from './BookClearing.sol';
import {BookListing} from './BookListing.sol';
import {BookMath} from './BookMath.sol';
import {BookOracle} from './BookOracle.sol';
import {BookTypes} from './BookTypes.sol';
import {VaultNotes} from './VaultNotes.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';

/// @title SealedBook
/// @notice Periodic sealed double auction. Epochs are 10 minutes: commit 8, reveal 2, then one epoch to settle.
/// @dev The escrow token makes the side public. A preimage whose side or epoch disagrees with the commit is rejected
///      and does not consume the commitment; `claimUnrevealed` returns the token that was actually escrowed.
///      Flag bit 0 carries a valid revealed order only when a timely settle hits the oracle band, for at most
///      MAX_CARRY flagged reveals per market and epoch. Other voids refund.
///      Vault-funded orders (committed by BookAdapter): fill proceeds always go to the order's recipient; only the
///      order's own unspent escrow goes back into the vault. A vault-funded commit may displace a public, unrevealed
///      copy of its commitment in the current epoch; the copy's escrow is returned to its payer in the same call.
contract SealedBook is ReentrancyGuard {
  using SafeERC20 for IERC20;

  IEntrypoint public immutable entrypoint;
  IWBNB public immutable wbnb;
  IERC20 public immutable usdt;

  address public treasury;
  address public owner;
  address public pendingOwner;
  address public adapter;
  uint256 public marketCount;

  mapping(uint256 => BookTypes.Market) internal markets;
  mapping(address => uint256) public marketOf;
  mapping(bytes32 => BookTypes.Order) internal orders;
  mapping(uint256 => mapping(uint64 => BookTypes.EpochState)) internal epochs;
  mapping(uint256 => mapping(uint64 => uint32)) public orderCount;
  mapping(uint256 => mapping(uint64 => BookTypes.Leaf[])) internal buys;
  mapping(uint256 => mapping(uint64 => BookTypes.Leaf[])) internal sells;
  mapping(uint256 => mapping(uint64 => bytes32[])) internal commitments;
  mapping(uint256 => mapping(uint64 => mapping(uint8 => mapping(uint256 => uint128)))) internal levelPrefix;
  /// @dev Carry-flagged valid reveals of an epoch, at most MAX_CARRY. Only these are carried on a band fail.
  mapping(uint256 => mapping(uint64 => bytes32[])) internal carryList;

  error PriceNotOnTick();
  error BadRange();
  error ZeroVolume();
  error EndpointVolumeMismatch();
  error LowerEndpointNotTight();
  error UpperEndpointNotTight();
  error BadPivot();
  error BadMarginalLevel();
  error OrdersCross();
  error InvariantBreak();
  error UnknownOrder();
  error UnknownMarket();
  error InvalidStatus();
  error NotCommitPhase();
  error NotRevealPhase();
  error NotSettlePhase();
  error SideMismatch();
  error EpochMismatch();
  error MalformedReveal();
  error AlreadyFinalized();
  error AlreadyClaimed();
  error EmptyEpoch();
  error NotFinalized();
  error VoidTooEarly();
  error InvalidPayment();
  error InvalidConfig();
  error PairExists();
  error UnexpectedNative();
  error OnlyOwner();
  error AdapterSet();
  error EpochFull();
  error PrefixOverflow();
  error DuplicateCommitment();
  error OnlySelf();
  error EscrowTooSmall();
  error OnlyRecipient();

  event PairListed(bytes32 indexed pairId, address indexed base, address indexed quote);
  event OrderCommitted(bytes32 indexed pairId, uint64 indexed epoch, bytes32 indexed commitment);
  event EpochSettled(
    bytes32 indexed pairId,
    uint64 indexed epoch,
    uint256 clearingPrice,
    uint256 baseVolume,
    uint256 quoteVolume,
    uint32 filledOrders
  );
  event EpochVoided(bytes32 indexed pairId, uint64 indexed epoch, uint8 reason);
  event OrderRevealed(bytes32 indexed commitment, uint8 validity);
  event OrderCarried(bytes32 indexed pairId, uint64 indexed fromEpoch, uint64 indexed toEpoch, bytes32 commitment);
  event CarrySkipped(bytes32 indexed commitment, uint64 indexed epoch);
  event FeesTaken(bytes32 indexed pairId, uint64 indexed epoch, uint256 amount);
  event OrderClaimed(bytes32 indexed commitment, address indexed recipient, uint256 baseAmount, uint256 quoteAmount);
  event ReferenceRead(uint256 indexed marketId, uint64 indexed epoch, uint256 price);
  /// @dev `pairId` / `epoch` are the displaced copy's: its OrderCommitted no longer stands for an order.
  event OrderDisplaced(
    bytes32 indexed pairId, uint64 indexed epoch, bytes32 indexed commitment, address payer, uint256 escrow
  );
  event MinEscrowSet(uint256 indexed marketId, uint256 minQuote, uint256 minBase);
  event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  struct Refund {
    address token;
    address to;
    uint256 amount;
  }

  modifier onlyOwner() {
    if (msg.sender != owner) revert OnlyOwner();
    _;
  }

  constructor(address entrypoint_, address wbnb_, address usdt_, address treasury_, address owner_) {
    if (entrypoint_.code.length == 0 || wbnb_.code.length == 0 || usdt_.code.length == 0) revert InvalidConfig();
    if (treasury_ == address(0) || owner_ == address(0)) revert InvalidConfig();
    entrypoint = IEntrypoint(entrypoint_);
    wbnb = IWBNB(wbnb_);
    usdt = IERC20(usdt_);
    treasury = treasury_;
    owner = owner_;
  }

  receive() external payable {
    if (msg.sender != address(wbnb)) revert UnexpectedNative();
  }

  function maxOrders() external pure returns (uint32) {
    return BookTypes.MAX_ORDERS;
  }

  function maxCarry() external pure returns (uint32) {
    return BookTypes.MAX_CARRY;
  }

  /// @notice Smallest escrow `commit` accepts: USDT for a buy, base units for a sell.
  function minEscrow(uint256 marketId) external view returns (uint256 minQuote, uint256 minBase) {
    BookTypes.Market storage m = markets[marketId];
    if (!m.listed) revert UnknownMarket();
    return (m.minQuote, m.minBase);
  }

  function currentEpoch() public view returns (uint64) {
    return uint64(block.timestamp / BookTypes.EPOCH_SECONDS);
  }

  function phaseOf(uint64 epoch) external view returns (uint8) {
    return BookTypes.phaseAt(epoch, block.timestamp);
  }

  function pairTokens(uint256 marketId) external view returns (address base, address quoteToken) {
    BookTypes.Market storage m = markets[marketId];
    if (!m.listed) revert UnknownMarket();
    return (m.base, address(usdt));
  }

  function depth(uint256 marketId, uint64 epoch) external view returns (uint256 buyN, uint256 sellN) {
    return (buys[marketId][epoch].length, sells[marketId][epoch].length);
  }

  /// @dev Split so neither getter copies the whole epoch onto the legacy stack.
  function epochHead(
    uint256 marketId,
    uint64 epoch
  )
    external
    view
    returns (uint8 status, uint8 voidReason, uint8 longSide, uint64 finalizedAt, uint256 price, uint256 volume)
  {
    BookTypes.EpochState storage ep = epochs[marketId][epoch];
    return (ep.status, ep.voidReason, ep.longSide, ep.finalizedAt, ep.price, ep.volume);
  }

  function epochTail(
    uint256 marketId,
    uint64 epoch
  )
    external
    view
    returns (
      uint256 marginalLevel,
      uint256 marginalRemaining,
      uint256 marginalTotal,
      uint256 quoteVolume,
      uint32 filledOrders,
      uint256 treasuryPaid
    )
  {
    BookTypes.EpochState storage ep = epochs[marketId][epoch];
    return (ep.marginalLevel, ep.marginalRemaining, ep.marginalTotal, ep.quoteVolume, ep.filledOrders, ep.treasuryPaid);
  }

  function buyEscrowRequired(uint256 quantity, uint256 limitPrice) external pure returns (uint256) {
    return BookMath.buyEscrowRequired(quantity, limitPrice);
  }

  function referencePrice(uint256 marketId) external view returns (uint256) {
    BookTypes.Market memory m = markets[marketId];
    if (!m.listed) revert UnknownMarket();
    return BookOracle.readReferenceLinked(m, address(usdt));
  }

  function computeCommitment(
    uint256 marketId,
    uint64 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    address recipient,
    bytes32 refundsHash,
    uint8 flags,
    bytes32 salt
  ) external view returns (bytes32) {
    return BookMath.hashOrder(
      block.chainid, address(this), marketId, epochId, side, limitPrice, quantity, recipient, refundsHash, flags, salt
    );
  }

  function preview(
    uint256 marketId,
    uint64 epoch,
    uint256 pLow,
    uint256 pHigh,
    uint256 pivot,
    uint256 marginal
  ) external view returns (uint8 code, BookTypes.Clearing memory clearing) {
    BookTypes.Market memory m = markets[marketId];
    if (!m.listed) revert UnknownMarket();
    BookClearing.Hint memory hint;
    hint.tick = m.tick;
    hint.pLow = pLow;
    hint.pHigh = pHigh;
    hint.pivot = pivot;
    hint.marginal = marginal;
    hint.ref = BookOracle.readReferenceLinked(m, address(usdt));
    return this.quote(marketId, epoch, hint);
  }

  /// @dev Depth and the certificate share this frame. Fees are a later call.
  function evaluate(
    uint256 marketId,
    uint64 epoch,
    BookClearing.Hint memory hint
  )
    external
    view
    returns (
      uint8 code,
      uint256 price,
      uint256 volume,
      uint8 longSide,
      uint256 marginalLevel,
      uint256 marginalRemaining,
      uint256 marginalTotal
    )
  {
    BookTypes.Clearing memory clearing;
    (code, clearing) = BookClearing.evaluateLinked(buys[marketId][epoch], sells[marketId][epoch], hint);
    return (
      code,
      clearing.price,
      clearing.volume,
      clearing.longSide,
      clearing.marginalLevel,
      clearing.marginalRemaining,
      clearing.marginalTotal
    );
  }

  /// @dev Assembles a clearing, then the fee walk when the book actually crosses inside the band.
  function quote(
    uint256 marketId,
    uint64 epoch,
    BookClearing.Hint memory hint
  ) external view returns (uint8 code, BookTypes.Clearing memory clearing) {
    (
      code,
      clearing.price,
      clearing.volume,
      clearing.longSide,
      clearing.marginalLevel,
      clearing.marginalRemaining,
      clearing.marginalTotal
    ) = this.evaluate(marketId, epoch, hint);
    if (code != BookTypes.OK_CLEARED) return (code, clearing);
    return this.account(marketId, epoch, clearing);
  }

  /// @dev One side of the fee walk, in its own frame.
  function walkSide(
    uint256 marketId,
    uint64 epoch,
    uint8 which,
    BookTypes.Clearing memory clearing
  ) external view returns (uint256 filled, uint256 notional, uint256 fees, uint32 count) {
    if (which == BookTypes.SIDE_BUY) return BookClearing.sideLinked(buys[marketId][epoch], which, clearing);
    return BookClearing.sideLinked(sells[marketId][epoch], which, clearing);
  }

  function account(
    uint256 marketId,
    uint64 epoch,
    BookTypes.Clearing memory clearing
  ) external view returns (uint8, BookTypes.Clearing memory) {
    (uint256 buyFill, uint256 buyCost, uint256 buyFee, uint32 buyCount) =
      this.walkSide(marketId, epoch, BookTypes.SIDE_BUY, clearing);
    (uint256 sellFill, uint256 sellGross, uint256 sellFee, uint32 sellCount) =
      this.walkSide(marketId, epoch, BookTypes.SIDE_SELL, clearing);
    if (buyFill != clearing.volume || sellFill != clearing.volume || buyCost < sellGross) {
      return (BookTypes.ERR_INVARIANT, clearing);
    }
    clearing.buyFees = buyFee;
    clearing.sellFees = sellFee;
    clearing.quoteVolume = buyCost;
    clearing.roundingSurplus = buyCost - sellGross;
    clearing.filledOrders = buyCount + sellCount;
    return (BookTypes.OK_CLEARED, clearing);
  }

  function previewNoCross(uint256 marketId, uint64 epoch) external view returns (uint8) {
    if (!markets[marketId].listed) revert UnknownMarket();
    return BookClearing.diagnoseNoCrossLinked(buys[marketId][epoch], sells[marketId][epoch]);
  }

  function previewPayment(bytes32 commitment) external view returns (BookTypes.Payment memory) {
    BookTypes.Order storage o = orders[commitment];
    if (o.payer == address(0)) revert UnknownOrder();
    return
      BookMath.payment(o.side, o.limitPrice, o.quantity, o.prefix, o.escrow, o.validity, epochs[o.marketId][o.epoch]);
  }

  function orderBrief(bytes32 commitment)
    external
    view
    returns (
      uint64 epoch,
      uint8 side,
      uint8 validity,
      uint8 flags,
      bool vaultFunded,
      bool claimed,
      uint128 escrow,
      address recipient
    )
  {
    BookTypes.Order storage o = orders[commitment];
    return (o.epoch, o.side, o.validity, o.flags, o.vaultFunded, o.claimed, o.escrow, o.recipient);
  }

  /// @notice Two-step transfer: `next` becomes owner only after it calls `acceptOwnership`. Zero cancels.
  function transferOwnership(address next) external onlyOwner {
    pendingOwner = next;
    emit OwnershipTransferStarted(owner, next);
  }

  function acceptOwnership() external {
    if (msg.sender != pendingOwner) revert OnlyOwner();
    emit OwnershipTransferred(owner, msg.sender);
    owner = msg.sender;
    pendingOwner = address(0);
  }

  /// @notice Minimum escrow per commit. Both must be non-zero.
  function setMinEscrow(uint256 marketId, uint128 minQuote, uint128 minBase) external onlyOwner {
    BookTypes.Market storage m = markets[marketId];
    if (!m.listed) revert UnknownMarket();
    if (minQuote == 0 || minBase == 0) revert InvalidConfig();
    m.minQuote = minQuote;
    m.minBase = minBase;
    emit MinEscrowSet(marketId, minQuote, minBase);
  }

  /// @dev Once, after BookAdapter exists. Orders committed earlier cannot deposit proceeds back to the vault.
  function setAdapter(address adapter_) external onlyOwner {
    if (adapter != address(0)) revert AdapterSet();
    if (adapter_.code.length == 0) revert InvalidConfig();
    adapter = adapter_;
  }

  function listChainlinkPair(
    address base,
    uint128 tick,
    uint128 lot,
    address baseFeed,
    address quoteFeed,
    uint32 baseHeartbeat,
    uint32 quoteHeartbeat
  ) external onlyOwner nonReentrant returns (uint256 marketId) {
    _checkNewPair(base, tick, lot);
    marketId = ++marketCount;
    BookListing.chainlinkLinked(
      markets[marketId], base, tick, lot, baseFeed, quoteFeed, baseHeartbeat, quoteHeartbeat
    );
    _listed(marketId, base);
  }

  function listTwapPair(
    address base,
    uint128 tick,
    uint128 lot,
    address pool
  ) external onlyOwner nonReentrant returns (uint256 marketId) {
    _checkNewPair(base, tick, lot);
    marketId = ++marketCount;
    BookListing.twapLinked(markets[marketId], base, address(usdt), tick, lot, pool);
    _listed(marketId, base);
  }

  function _listed(uint256 marketId, address base) private {
    marketOf[base] = marketId;
    emit PairListed(bytes32(marketId), base, address(usdt));
    (uint256 minQuote, uint256 minBase) = BookListing.defaultMinEscrowLinked(markets[marketId], marketId);
    emit MinEscrowSet(marketId, minQuote, minBase);
  }

  function commit(uint256 marketId, bytes32 commitment, uint8 side, uint256 amount) external payable nonReentrant {
    if (msg.value != 0) revert UnexpectedNative();
    BookTypes.Market memory m = markets[marketId];
    if (!m.listed) revert UnknownMarket();
    uint64 epoch = currentEpoch();
    if (BookTypes.phaseAt(epoch, block.timestamp) != BookTypes.PHASE_COMMIT) revert NotCommitPhase();
    if (side > BookTypes.SIDE_SELL || amount > BookTypes.MAX_UINT128) revert MalformedReveal();
    if (amount < (side == BookTypes.SIDE_BUY ? m.minQuote : m.minBase)) revert EscrowTooSmall();
    bool vault = msg.sender == adapter;
    BookTypes.Order storage o = orders[commitment];
    bool sameSlot;
    Refund memory displaced;
    if (o.payer != address(0)) {
      // only a vault-funded commit may take over a public, unrevealed copy committed in this epoch.
      if (!vault || o.vaultFunded || o.epoch != epoch || o.validity != BookTypes.UNREVEALED || o.claimed) {
        revert DuplicateCommitment();
      }
      sameSlot = o.marketId == marketId;
      displaced = _displace(o, commitment);
    }
    if (!sameSlot) {
      if (orderCount[marketId][epoch] >= BookTypes.MAX_ORDERS) revert EpochFull();
      commitments[marketId][epoch].push(commitment);
      orderCount[marketId][epoch] += 1;
    }
    o.escrow = uint128(amount);
    o.epoch = epoch;
    o.marketId = uint32(marketId);
    o.side = side;
    o.vaultFunded = vault;
    o.payer = msg.sender;
    IERC20 token = side == BookTypes.SIDE_BUY ? usdt : IERC20(m.base);
    uint256 beforeBal = token.balanceOf(address(this));
    token.safeTransferFrom(msg.sender, address(this), amount);
    if (token.balanceOf(address(this)) - beforeBal != amount) revert InvalidPayment();
    emit OrderCommitted(bytes32(marketId), epoch, commitment);
    if (displaced.amount != 0) IERC20(displaced.token).safeTransfer(displaced.to, displaced.amount);
  }

  function reveal(
    uint256 marketId,
    uint64 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    address recipient,
    uint256[] calldata precommitments,
    uint8 flags,
    bytes32 salt
  ) external nonReentrant {
    _checkShape(recipient, side, flags, limitPrice, quantity, precommitments);
    bytes32 commitment = _hash(marketId, epochId, side, limitPrice, quantity, recipient, precommitments, flags, salt);
    _storeReveal(commitment, marketId, epochId, side, limitPrice, quantity, recipient, flags, precommitments);
  }

  function settle(
    uint256 marketId,
    uint64 epoch,
    uint256 pLow,
    uint256 pHigh,
    uint256 pivot,
    uint256 marginal
  ) external nonReentrant {
    BookTypes.Market memory market = _openSettle(marketId, epoch);
    uint256 ref = BookOracle.readReferenceLinked(market, address(usdt));
    emit ReferenceRead(marketId, epoch, ref);
    _apply(marketId, epoch, market.tick, pLow, pHigh, pivot, marginal, ref);
  }

  function settleNoCross(uint256 marketId, uint64 epoch) external nonReentrant {
    _openSettle(marketId, epoch);
    if (BookClearing.diagnoseNoCrossLinked(buys[marketId][epoch], sells[marketId][epoch]) != BookTypes.OK_NO_CROSS) {
      revert OrdersCross();
    }
    uint8 reason = _anyRevealed(marketId, epoch) ? BookTypes.VOID_NO_CROSS : BookTypes.VOID_NO_REVEALS;
    _void(marketId, epoch, reason, 0);
  }

  function voidExpired(uint256 marketId, uint64 epoch) external nonReentrant {
    if (!markets[marketId].listed) revert UnknownMarket();
    if (epochs[marketId][epoch].status != BookTypes.EPOCH_PENDING) revert AlreadyFinalized();
    if (orderCount[marketId][epoch] == 0) revert EmptyEpoch();
    if (BookTypes.phaseAt(epoch, block.timestamp) != BookTypes.PHASE_EXPIRED) revert VoidTooEarly();
    _void(marketId, epoch, BookTypes.VOID_TIMEOUT, 0);
  }

  function claim(bytes32 commitment, uint256[] calldata precommitments) external nonReentrant {
    _claim(commitment, precommitments, true);
  }

  function claimToRecipient(bytes32 commitment, uint256[] calldata precommitments) external nonReentrant {
    _claim(commitment, precommitments, false);
  }

  function claimUnrevealed(
    uint256 marketId,
    uint64 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    address recipient,
    uint256[] calldata precommitments,
    uint8 flags,
    bytes32 salt
  ) external nonReentrant {
    if (recipient == address(0)) revert MalformedReveal();
    bytes32 commitment = _hash(marketId, epochId, side, limitPrice, quantity, recipient, precommitments, flags, salt);
    BookTypes.Order storage o = orders[commitment];
    if (o.payer == address(0)) revert UnknownOrder();
    if (o.validity != BookTypes.UNREVEALED || o.claimed) revert InvalidStatus();
    if (epochs[o.marketId][o.epoch].status == BookTypes.EPOCH_PENDING) revert NotFinalized();
    o.claimed = true;
    BookTypes.Payment memory p;
    if (o.side == BookTypes.SIDE_BUY) p.quoteRefund = o.escrow;
    else p.baseRefund = o.escrow;
    uint256 storedMarket = o.marketId;
    bool toVault = o.vaultFunded && precommitments.length != 0;
    _disburse(storedMarket, p, recipient, toVault, precommitments);
    emit OrderClaimed(commitment, recipient, p.baseRefund, p.quoteRefund);
  }

  /// @dev What the displaced public copy is owed. The caller overwrites the record (so the copy can never be revealed
  ///      or claimed) and pays this out last. Listed tokens are plain ERC-20s without receive hooks.
  function _displace(BookTypes.Order storage o, bytes32 commitment) private returns (Refund memory r) {
    r.to = o.payer;
    r.amount = o.escrow;
    r.token = o.side == BookTypes.SIDE_BUY ? address(usdt) : markets[o.marketId].base;
    emit OrderDisplaced(bytes32(uint256(o.marketId)), o.epoch, commitment, r.to, r.amount);
  }

  function _checkNewPair(address base, uint128 tick, uint128 lot) private view {
    if (base == address(0) || base == address(usdt) || tick == 0 || lot == 0) revert InvalidConfig();
    if (base.code.length == 0) revert InvalidConfig();
    if (marketOf[base] != 0) revert PairExists();
  }

  function _checkShape(
    address recipient,
    uint8 side,
    uint8 flags,
    uint256 limitPrice,
    uint256 quantity,
    uint256[] calldata precommitments
  ) private pure {
    if (recipient == address(0) || flags > 1 || side > BookTypes.SIDE_SELL) revert MalformedReveal();
    if (limitPrice > BookTypes.MAX_UINT128 || quantity > BookTypes.MAX_UINT128) revert MalformedReveal();
    uint256 n = precommitments.length;
    if (n > BookTypes.MAX_REFUND_NOTES) revert MalformedReveal();
    for (uint256 i; i < n; ++i) {
      uint256 pc = precommitments[i];
      if (pc == 0 || pc >= BookTypes.SNARK_SCALAR_FIELD) revert MalformedReveal();
    }
  }

  function _hash(
    uint256 marketId,
    uint64 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    address recipient,
    uint256[] calldata precommitments,
    uint8 flags,
    bytes32 salt
  ) private view returns (bytes32) {
    return BookMath.hashOrder(
      block.chainid,
      address(this),
      marketId,
      epochId,
      side,
      limitPrice,
      quantity,
      recipient,
      keccak256(abi.encodePacked(precommitments)),
      flags,
      salt
    );
  }

  function _storeReveal(
    bytes32 commitment,
    uint256 marketId,
    uint64 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity,
    address recipient,
    uint8 flags,
    uint256[] calldata precommitments
  ) private {
    BookTypes.Order storage o = orders[commitment];
    if (o.payer == address(0)) revert UnknownOrder();
    if (o.validity != BookTypes.UNREVEALED || o.claimed) revert InvalidStatus();
    if (o.side != side) revert SideMismatch();
    if (o.epoch != epochId || o.marketId != marketId) revert EpochMismatch();
    if (BookTypes.phaseAt(epochId, block.timestamp) != BookTypes.PHASE_REVEAL) revert NotRevealPhase();
    BookTypes.Market memory m = markets[marketId];
    uint8 code = BookMath.validity(side, limitPrice, quantity, o.escrow, m.tick, m.lot);
    if (code == BookTypes.VALID) {
      _pushLeaf(o, marketId, epochId, side, limitPrice, quantity);
      if (flags & 1 != 0) _listCarry(marketId, epochId, commitment);
    }
    o.limitPrice = uint128(limitPrice);
    o.quantity = uint128(quantity);
    o.flags = flags;
    o.validity = code;
    o.recipient = recipient;
    o.refundsHash = keccak256(abi.encodePacked(precommitments));
    emit OrderRevealed(commitment, code);
  }

  function _pushLeaf(
    BookTypes.Order storage o,
    uint256 marketId,
    uint64 epochId,
    uint8 side,
    uint256 limitPrice,
    uint256 quantity
  ) private {
    uint256 prefix = levelPrefix[marketId][epochId][side][limitPrice];
    if (prefix + quantity > BookTypes.MAX_UINT128) revert PrefixOverflow();
    levelPrefix[marketId][epochId][side][limitPrice] = uint128(prefix + quantity);
    BookTypes.Leaf memory leaf = BookTypes.Leaf(uint128(limitPrice), uint128(quantity), uint128(prefix), o.escrow);
    if (side == BookTypes.SIDE_BUY) buys[marketId][epochId].push(leaf);
    else sells[marketId][epochId].push(leaf);
    o.prefix = uint128(prefix);
  }

  /// @dev A flagged order beyond MAX_CARRY still trades; it is refunded instead of carried on a band fail.
  function _listCarry(uint256 marketId, uint64 epoch, bytes32 commitment) private {
    bytes32[] storage list = carryList[marketId][epoch];
    if (list.length >= BookTypes.MAX_CARRY) {
      emit CarrySkipped(commitment, epoch);
      return;
    }
    list.push(commitment);
  }

  function _openSettle(uint256 marketId, uint64 epoch) private view returns (BookTypes.Market memory market) {
    market = markets[marketId];
    if (!market.listed) revert UnknownMarket();
    if (epochs[marketId][epoch].status != BookTypes.EPOCH_PENDING) revert AlreadyFinalized();
    if (orderCount[marketId][epoch] == 0) revert EmptyEpoch();
    if (BookTypes.phaseAt(epoch, block.timestamp) != BookTypes.PHASE_SETTLE) revert NotSettlePhase();
  }

  function _apply(
    uint256 marketId,
    uint64 epoch,
    uint256 tick,
    uint256 pLow,
    uint256 pHigh,
    uint256 pivot,
    uint256 marginal,
    uint256 ref
  ) private {
    BookClearing.Hint memory hint;
    hint.tick = tick;
    hint.pLow = pLow;
    hint.pHigh = pHigh;
    hint.pivot = pivot;
    hint.marginal = marginal;
    hint.ref = ref;
    (uint8 code, BookTypes.Clearing memory clearing) = this.quote(marketId, epoch, hint);
    if (code == BookTypes.OK_CLEARED) {
      _storeCleared(marketId, epoch, clearing);
    } else if (code == BookTypes.OK_BAND) {
      _void(marketId, epoch, BookTypes.VOID_BAND, clearing.price);
      _carry(marketId, epoch);
    } else {
      _revertCode(code);
    }
  }

  function _storeCleared(uint256 marketId, uint64 epoch, BookTypes.Clearing memory clearing) private {
    uint256 paid = clearing.buyFees + clearing.sellFees + clearing.roundingSurplus;
    BookTypes.EpochState storage ep = epochs[marketId][epoch];
    ep.status = BookTypes.EPOCH_CLEARED;
    ep.longSide = clearing.longSide;
    ep.finalizedAt = uint64(block.timestamp);
    ep.price = clearing.price;
    ep.volume = clearing.volume;
    ep.marginalLevel = clearing.marginalLevel;
    ep.marginalRemaining = clearing.marginalRemaining;
    ep.marginalTotal = clearing.marginalTotal;
    ep.quoteVolume = clearing.quoteVolume;
    ep.filledOrders = clearing.filledOrders;
    ep.treasuryPaid = paid;
    if (paid != 0) usdt.safeTransfer(treasury, paid);
    emit EpochSettled(
      bytes32(marketId), epoch, clearing.price, clearing.volume, clearing.quoteVolume, clearing.filledOrders
    );
    emit FeesTaken(bytes32(marketId), epoch, paid);
  }

  function _void(uint256 marketId, uint64 epoch, uint8 reason, uint256 price) private {
    BookTypes.EpochState storage ep = epochs[marketId][epoch];
    ep.status = BookTypes.EPOCH_VOIDED;
    ep.voidReason = reason;
    ep.price = price;
    ep.finalizedAt = uint64(block.timestamp);
    emit EpochVoided(bytes32(marketId), epoch, reason);
  }

  function _carry(uint256 marketId, uint64 epoch) private {
    uint64 next = epoch + 1;
    if (epochs[marketId][next].status != BookTypes.EPOCH_PENDING) return;
    uint8 phase = BookTypes.phaseAt(next, block.timestamp);
    if (phase != BookTypes.PHASE_COMMIT && phase != BookTypes.PHASE_REVEAL) return;
    bytes32[] storage list = carryList[marketId][epoch];
    uint256 n = list.length;
    for (uint256 i; i < n; ++i) {
      _carryOne(marketId, epoch, next, list[i]);
    }
  }

  /// @dev Invalid or unflagged orders stay on the voided epoch and are refunded. A full next epoch is skipped, not reverted.
  function _carryOne(uint256 marketId, uint64 epoch, uint64 next, bytes32 commitment) private {
    BookTypes.Order storage o = orders[commitment];
    if (o.claimed || o.validity != BookTypes.VALID || (o.flags & 1) == 0 || o.epoch != epoch) return;
    if (orderCount[marketId][next] >= BookTypes.MAX_ORDERS) {
      emit CarrySkipped(commitment, epoch);
      return;
    }
    uint256 prefix = levelPrefix[marketId][next][o.side][o.limitPrice];
    if (prefix + o.quantity > BookTypes.MAX_UINT128) {
      emit CarrySkipped(commitment, epoch);
      return;
    }
    levelPrefix[marketId][next][o.side][o.limitPrice] = uint128(prefix + o.quantity);
    BookTypes.Leaf memory leaf = BookTypes.Leaf(o.limitPrice, o.quantity, uint128(prefix), o.escrow);
    if (o.side == BookTypes.SIDE_BUY) buys[marketId][next].push(leaf);
    else sells[marketId][next].push(leaf);
    o.prefix = uint128(prefix);
    o.epoch = next;
    commitments[marketId][next].push(commitment);
    orderCount[marketId][next] += 1;
    _listCarry(marketId, next, commitment);
    emit OrderCarried(bytes32(marketId), epoch, next, commitment);
  }

  function _anyRevealed(uint256 marketId, uint64 epoch) private view returns (bool) {
    bytes32[] storage list = commitments[marketId][epoch];
    uint256 n = list.length;
    for (uint256 i; i < n; ++i) {
      BookTypes.Order storage o = orders[list[i]];
      if (o.validity != BookTypes.UNREVEALED && o.epoch == epoch && o.marketId == marketId) return true;
    }
    return false;
  }

  function _claim(bytes32 commitment, uint256[] calldata precommitments, bool allowVault) private {
    BookTypes.Order storage o = orders[commitment];
    if (o.payer == address(0)) revert UnknownOrder();
    if (o.validity == BookTypes.UNREVEALED) revert InvalidStatus();
    if (o.claimed) revert AlreadyClaimed();
    BookTypes.EpochState memory ep = epochs[o.marketId][o.epoch];
    if (ep.status == BookTypes.EPOCH_PENDING) revert NotFinalized();
    if (keccak256(abi.encodePacked(precommitments)) != o.refundsHash) revert MalformedReveal();
    // only the recipient may divert a vault-funded order's refund away from the vault.
    if (!allowVault && o.vaultFunded && msg.sender != o.recipient) revert OnlyRecipient();
    o.claimed = true;
    BookTypes.Payment memory p = BookMath.payment(o.side, o.limitPrice, o.quantity, o.prefix, o.escrow, o.validity, ep);
    address recipient = o.recipient;
    uint256 marketId = o.marketId;
    bool toVault = allowVault && o.vaultFunded;
    _disburse(marketId, p, recipient, toVault, precommitments);
    emit OrderClaimed(commitment, recipient, p.baseOut + p.baseRefund, p.quoteOut + p.quoteRefund);
  }

  /// @dev fill proceeds (`baseOut`, `quoteOut`) always go to `recipient`. With `toVault`, only the order's
  ///      own unspent escrow (`quoteRefund`, or a WBNB `baseRefund`) becomes vault notes: quote notes consume
  ///      precommitments from index 0, WBNB notes continue at the returned cursor. Note dust goes to `recipient`.
  function _disburse(
    uint256 marketId,
    BookTypes.Payment memory p,
    address recipient,
    bool toVault,
    uint256[] calldata precommitments
  ) private {
    uint256 quoteRefund = p.quoteRefund;
    uint256 baseRefund = p.baseRefund;
    address base = markets[marketId].base;
    if (toVault && precommitments.length != 0) {
      VaultNotes.Run memory run;
      run.entrypoint = address(entrypoint);
      run.wbnb = address(wbnb);
      run.quoteToken = address(usdt);
      run.end = precommitments.length;
      if (quoteRefund != 0) {
        run.native = false;
        run.remaining = quoteRefund;
        run.cursor = 0;
        (quoteRefund,, run.cursor) = this.settleNotes(run, precommitments);
      }
      if (baseRefund != 0 && base == address(wbnb)) {
        run.native = true;
        run.remaining = baseRefund;
        run.dust = 0;
        run.notes = 0;
        (baseRefund,,) = this.settleNotes(run, precommitments);
      }
    }
    uint256 quoteAmt = p.quoteOut + quoteRefund;
    uint256 baseAmt = p.baseOut + baseRefund;
    if (quoteAmt != 0) usdt.safeTransfer(recipient, quoteAmt);
    if (baseAmt != 0) IERC20(base).safeTransfer(recipient, baseAmt);
  }

  /// @dev Self-call so the note split is not inlined into `claim`.
  function settleNotes(
    VaultNotes.Run memory run,
    uint256[] calldata pcs
  ) external returns (uint256 dust, uint256 notes, uint256 cursor) {
    if (msg.sender != address(this)) revert OnlySelf();
    return VaultNotes.split(run, pcs);
  }

  function _revertCode(uint8 code) private pure {
    if (code == BookTypes.ERR_TICK) revert PriceNotOnTick();
    if (code == BookTypes.ERR_RANGE) revert BadRange();
    if (code == BookTypes.ERR_ZERO_VOL) revert ZeroVolume();
    if (code == BookTypes.ERR_ENDPOINT) revert EndpointVolumeMismatch();
    if (code == BookTypes.ERR_LOWER) revert LowerEndpointNotTight();
    if (code == BookTypes.ERR_UPPER) revert UpperEndpointNotTight();
    if (code == BookTypes.ERR_PIVOT) revert BadPivot();
    if (code == BookTypes.ERR_MARGINAL) revert BadMarginalLevel();
    if (code == BookTypes.ERR_CROSS) revert OrdersCross();
    revert InvariantBreak();
  }
}
