// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HushToken} from './HushToken.sol';
import {LaunchConstants, LaunchParams, SaleConfig} from './LaunchTypes.sol';
import {SaleDeployer} from './SaleDeployer.sol';
import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {VestingWallet} from '@openzeppelin/contracts/finance/VestingWallet.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

interface ISealedSaleFees {
  function collectFees(uint256 saleId_) external;
}

/// @title LaunchFactory
/// @notice Validates creator parameters  and deploys a HushToken plus its SealedSale.
contract LaunchFactory is Ownable2Step {
  using SafeERC20 for IERC20;

  struct Deployment {
    address entrypoint;
    address wbnb;
    address usdt;
    address pancakeFactory;
    address positionManager;
    address treasury;
    address saleDeployer;
    uint256[5] bnbUnits;
    uint256[5] usdtUnits;
  }

  /// @notice Off-chain sale profile (logo, description, links) anchored on-chain: `contentHash` is the
  ///         keccak256 of the canonical profile JSON served at `uri`; readers must verify it before display.
  struct Profile {
    bytes32 contentHash;
    string uri;
    uint64 updatedAt;
  }

  uint256 public constant MAX_PROFILE_URI = 200;

  address public immutable entrypoint;
  address public immutable wbnb;
  address public immutable usdt;
  address public immutable pancakeFactory;
  address public immutable positionManager;
  SaleDeployer public immutable saleDeployer;
  address public treasury;
  /// @notice Processooor allowed to commit below one full unit. Set once, before sales that use it.
  address public launchAdapter;

  uint256[5] internal _bnbUnits;
  uint256[5] internal _usdtUnits;

  address[] public sales;
  mapping(address sale => bool) public isSale;
  /// @notice Who created each sale (the only account that may set its profile).
  mapping(address sale => address) public creatorOf;
  mapping(address sale => uint256) internal _saleIdPlusOne;
  mapping(address sale => Profile) internal _profiles;

  error InvalidConfig();
  error InvalidQuoteAsset();
  error InvalidName();
  error InvalidSupply();
  error InvalidPrice();
  error InvalidMinRaise();
  error InvalidDuration();
  error InvalidLiquidity();
  error InvalidCreatorShare();
  error InvalidVesting();
  error InvalidMaxBids();
  error AdapterAlreadySet();
  error UnknownSale();
  error NotSaleCreator();
  error InvalidProfile();

  event TreasuryUpdated(address indexed treasury);
  event LaunchAdapterSet(address indexed adapter);
  /// @dev Indexer event (services/indexer HushCrossIndexedEvents): exact signature.
  event SaleCreated(
    uint256 indexed saleId,
    address indexed token,
    address indexed creator,
    address quoteAsset,
    uint256 tokensForSale,
    uint256 floorPrice,
    uint256 minRaise,
    uint64 commitEnd,
    uint64 revealEnd
  );
  /// @dev Additional event: where the sale and the creator vesting wallet live.
  event SaleDeployed(uint256 indexed saleId, address indexed sale, address vesting);
  /// @dev Indexer event: the profile pointer of a sale changed (zero hash + empty uri = cleared).
  event SaleProfileSet(
    uint256 indexed saleId, address indexed sale, address indexed creator, bytes32 contentHash, string uri
  );

  constructor(address owner_, Deployment memory d) Ownable(owner_) {
    if (
      d.entrypoint.code.length == 0 || d.wbnb.code.length == 0 || d.usdt.code.length == 0
        || d.pancakeFactory.code.length == 0 || d.positionManager.code.length == 0 || d.saleDeployer.code.length == 0
        || d.treasury == address(0)
    ) revert InvalidConfig();
    _checkUnits(d.bnbUnits);
    _checkUnits(d.usdtUnits);
    entrypoint = d.entrypoint;
    wbnb = d.wbnb;
    usdt = d.usdt;
    pancakeFactory = d.pancakeFactory;
    positionManager = d.positionManager;
    saleDeployer = SaleDeployer(d.saleDeployer);
    treasury = d.treasury;
    _bnbUnits = d.bnbUnits;
    _usdtUnits = d.usdtUnits;
  }

  function setTreasury(address treasury_) external onlyOwner {
    if (treasury_ == address(0)) revert InvalidConfig();
    treasury = treasury_;
    emit TreasuryUpdated(treasury_);
  }

  /// @notice Register the LaunchAdapter once. Only that address may commit at the private minimum.
  function setLaunchAdapter(address adapter_) external onlyOwner {
    if (launchAdapter != address(0)) revert AdapterAlreadySet();
    if (adapter_.code.length == 0) revert InvalidConfig();
    launchAdapter = adapter_;
    emit LaunchAdapterSet(adapter_);
  }

  /// @notice Anyone may collect locked-LP trading fees for `saleId`. The sale splits them.
  function collectFees(uint256 saleId_) external {
    if (saleId_ >= sales.length) revert UnknownSale();
    ISealedSaleFees(sales[saleId_]).collectFees(saleId_);
  }

  /// @notice Set or clear the profile pointer of `sale`. Only the sale's creator may call it.
  /// @dev `uri` must be 1..MAX_PROFILE_URI bytes with a non-zero hash; zero hash with an empty uri clears it.
  function setProfile(address sale, bytes32 contentHash, string calldata uri) external {
    uint256 idPlusOne = _saleIdPlusOne[sale];
    if (idPlusOne == 0) revert UnknownSale();
    if (msg.sender != creatorOf[sale]) revert NotSaleCreator();
    uint256 len = bytes(uri).length;
    bool clearing = contentHash == bytes32(0) && len == 0;
    if (!clearing && (contentHash == bytes32(0) || len == 0 || len > MAX_PROFILE_URI)) revert InvalidProfile();
    if (clearing) delete _profiles[sale];
    else _profiles[sale] = Profile({contentHash: contentHash, uri: uri, updatedAt: uint64(block.timestamp)});
    emit SaleProfileSet(idPlusOne - 1, sale, msg.sender, contentHash, uri);
  }

  function profileOf(address sale) external view returns (Profile memory) {
    return _profiles[sale];
  }

  /// @notice Deploy a token, its sealed sale and (when a creator allocation exists) a linear vesting wallet.
  /// @dev Sale supply + LP reserve go to the sale; the creator allocation goes to an OpenZeppelin VestingWallet
  ///      (beneficiary = caller, start = reveal end, duration = vestingDuration).
  function createSale(LaunchParams calldata p) external returns (address sale, address token) {
    validateParams(p);
    uint256 saleId = sales.length;
    token = address(new HushToken(p.name, p.symbol, p.saleSupply + p.liquiditySupply + p.creatorSupply, address(this)));
    SaleConfig memory c = _config(p, saleId, token);
    sale = saleDeployer.deploy(c);
    sales.push(sale);
    isSale[sale] = true;
    creatorOf[sale] = msg.sender;
    _saleIdPlusOne[sale] = saleId + 1;
    IERC20(token).safeTransfer(sale, p.saleSupply + p.liquiditySupply);
    address vesting;
    if (p.creatorSupply != 0) {
      vesting = address(new VestingWallet(msg.sender, c.revealEnd, p.vestingDuration));
      IERC20(token).safeTransfer(vesting, p.creatorSupply);
    }
    emit SaleCreated(
      saleId, token, msg.sender, p.quoteAsset, p.saleSupply, p.floorPrice, p.minRaise, c.commitEnd, c.revealEnd
    );
    emit SaleDeployed(saleId, sale, vesting);
  }

  function _config(LaunchParams calldata p, uint256 saleId, address token) private view returns (SaleConfig memory c) {
    c.saleId = saleId;
    c.factory = address(this);
    c.creator = msg.sender;
    c.token = token;
    c.quoteAsset = p.quoteAsset;
    c.treasury = treasury;
    c.entrypoint = entrypoint;
    c.wbnb = wbnb;
    c.pancakeFactory = pancakeFactory;
    c.positionManager = positionManager;
    c.saleSupply = p.saleSupply;
    c.lpTokenReserve = p.liquiditySupply;
    c.floorPrice = p.floorPrice;
    c.minRaise = p.minRaise;
    c.minEscrow = minEscrowFor(p.quoteAsset);
    c.commitEnd = uint64(block.timestamp + p.commitDuration);
    c.revealEnd = uint64(block.timestamp + p.commitDuration + p.revealDuration);
    c.liquidityBps = p.liquidityBps;
    c.maxBids = p.maxBids;
    c.units = unitsFor(p.quoteAsset);
  }

  /// @notice Reverts with a specific error when a parameter violates the configured sale constraints.
  function validateParams(LaunchParams calldata p) public view {
    if (p.quoteAsset != address(0) && p.quoteAsset != usdt) revert InvalidQuoteAsset();
    if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert InvalidName();
    uint256 total = p.saleSupply + p.liquiditySupply + p.creatorSupply;
    if (p.saleSupply == 0 || total > LaunchConstants.MAX_AMOUNT) revert InvalidSupply();
    if (p.floorPrice == 0 || p.floorPrice > LaunchConstants.MAX_AMOUNT) revert InvalidPrice();
    if (p.minRaise > LaunchConstants.MAX_AMOUNT) revert InvalidMinRaise();
    if (
      p.commitDuration < LaunchConstants.MIN_COMMIT_DURATION || p.commitDuration > LaunchConstants.MAX_COMMIT_DURATION
        || p.revealDuration < LaunchConstants.MIN_REVEAL_DURATION
        || p.revealDuration > LaunchConstants.MAX_REVEAL_DURATION
    ) revert InvalidDuration();
    if (
      p.liquidityBps < LaunchConstants.MIN_LIQUIDITY_BPS || p.liquidityBps > LaunchConstants.MAX_LIQUIDITY_BPS
        || p.liquiditySupply * 10 < total
    ) revert InvalidLiquidity();
    if (p.creatorSupply * 10 > total) revert InvalidCreatorShare();
    if (
      p.creatorSupply != 0
        && (p.vestingDuration < LaunchConstants.MIN_VESTING_DURATION
          || p.vestingDuration > LaunchConstants.MAX_VESTING_DURATION)
    ) revert InvalidVesting();
    if (p.maxBids == 0 || p.maxBids > LaunchConstants.MAX_BIDS_LIMIT) revert InvalidMaxBids();
  }

  function unitsFor(address quoteAsset) public view returns (uint256[5] memory) {
    return quoteAsset == address(0) ? _bnbUnits : _usdtUnits;
  }

  /// @notice Minimum escrow per bid = the smallest vault Unit of the quote asset (LAUNCH.md section 1).
  function minEscrowFor(address quoteAsset) public view returns (uint256) {
    return unitsFor(quoteAsset)[0];
  }

  function saleCount() external view returns (uint256) {
    return sales.length;
  }

  function _checkUnits(uint256[5] memory u) private pure {
    if (u[0] == 0) revert InvalidConfig();
    for (uint256 i = 1; i < LaunchConstants.UNIT_COUNT; ++i) {
      if (u[i] <= u[i - 1]) revert InvalidConfig();
    }
  }
}
