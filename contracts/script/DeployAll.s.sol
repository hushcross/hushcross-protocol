// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';

import {BookAdapter} from '../src/book/BookAdapter.sol';
import {GiveAdapter} from '../src/give/GiveAdapter.sol';
import {GiveEscrow} from '../src/give/GiveEscrow.sol';
import {GiveRegistry} from '../src/give/GiveRegistry.sol';
import {SealedBook} from '../src/book/SealedBook.sol';
import {LaunchAdapter} from '../src/launch/LaunchAdapter.sol';
import {LaunchFactory} from '../src/launch/LaunchFactory.sol';
import {SaleDeployer} from '../src/launch/SaleDeployer.sol';
import {GiftAdapter} from '../src/send/GiftAdapter.sol';
import {HushSendAdapter} from '../src/send/HushSendAdapter.sol';
import {Constants} from 'contracts/lib/Constants.sol';

import {DeployVault} from './DeployVault.s.sol';

interface IChainlinkRound {
  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IPancakeV3FactoryView {
  function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title DeployAll
/// @notice Deploys the vault, HushSend, Gift, Launch, Book and Give and writes `deployments/<chainId>.json`.
/// @dev Supports chain id 56 and chain-56 fork rehearsals only, using the fixed external addresses.
///      Local deployment is not included. A chain-56 broadcast reverts before the first transaction
///      unless `CONFIRM_MAINNET=yes`. `DeployVault` itself still refuses every chain-56 broadcast.
contract DeployAll is DeployVault {
  address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
  address internal constant PANCAKE_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
  address internal constant PANCAKE_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
  address internal constant ANNOUNCER = 0x55649E01B5Df198D18D95b5cc5051630cfD45564;
  address internal constant REGISTRY = 0x6538E6bf4B0eBd30A8Ea093027Ac2422ce5d6538;
  address internal constant SANCTIONS_ORACLE = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;
  address internal constant BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
  address internal constant USDT_USD = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
  address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address internal constant ETH_TOKEN = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address internal constant BTC_USD = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
  address internal constant ETH_USD = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;
  /// @dev 0.01 quote wei per 1 base wei, scaled by 1e18. Lot is 0.001 base.
  uint128 internal constant TICK = 0.01e18;
  uint128 internal constant LOT = 0.001e18;
  /// @dev Default heartbeat per feed. Override per feed with `HEARTBEAT_<SYMBOL>_USD` (seconds), for example
  ///      `HEARTBEAT_USDT_USD=86400`, after checking that feed's configured heartbeat on data.chain.link.
  uint32 internal constant HEARTBEAT = 3600;

  struct External {
    address wbnb;
    address usdt;
    address pancakeFactory;
    address positionManager;
    address announcer;
    address registry;
    address sanctionsOracle;
    address bnbUsd;
    address usdtUsd;
    address treasury;
  }

  struct Product {
    address saleDeployer;
    address launchFactory;
    address launchAdapter;
    address hushSend;
    address gift;
  }

  struct Pair {
    string symbol;
    uint256 marketId;
    address base;
    address quoteToken;
    string oracle;
    address baseFeed;
    address quoteFeed;
    address pool;
    uint128 tick;
    uint128 lot;
  }

  struct Markets {
    address book;
    address bookAdapter;
    Pair wbnb;
    Pair btcb;
    Pair eth;
    address giveRegistry;
    address giveEscrow;
    address giveAdapter;
  }

  struct All {
    Result vault;
    External ext;
    Product product;
    Markets markets;
  }

  error ExternalHasNoCode();
  error MissingReference(string symbol);
  /// @dev a feed older than its heartbeat stops the deployment instead of being loosened.
  error StaleFeed(string name, uint256 age, uint256 heartbeat);

  /// @notice Broadcast every contract, then write the deployment file. Refuses an unconfirmed chain-56 broadcast.
  function run() external override {
    _refuseUnconfirmedMainnet();
    _requireChain56();
    uint256 startBlock = block.number;
    address owner = vm.envAddress('OWNER_ADDRESS');
    address postman = vm.envAddress('POSTMAN_ADDRESS');
    address treasury = vm.envOr('TREASURY_ADDRESS', owner);
    uint256 vettingFeeBPS = vm.envOr('VETTING_FEE_BPS', uint256(30));
    uint256 maxRelayFeeBPS = vm.envOr('MAX_RELAY_FEE_BPS', uint256(150));
    uint256 nativeMin = vm.envOr('NATIVE_MIN_DEPOSIT', uint256(0.02 ether));
    uint256 usdtMin = vm.envOr('USDT_MIN_DEPOSIT', uint256(20 ether));
    _assertMainnetCode();

    vm.startBroadcast(owner);
    All memory deployed = deployAll(owner, postman, treasury, false, nativeMin, usdtMin, vettingFeeBPS, maxRelayFeeBPS);
    vm.stopBroadcast();

    string memory path = _writeDeployment(startBlock, deployed);
    console2.log('Chain id', block.chainid);
    console2.log('Entrypoint', deployed.vault.entrypoint);
    console2.log('HushSend', deployed.product.hushSend);
    console2.log('Gift', deployed.product.gift);
    console2.log('LaunchFactory', deployed.product.launchFactory);
    console2.log('LaunchAdapter', deployed.product.launchAdapter);
    console2.log('SealedBook', deployed.markets.book);
    console2.log('BookAdapter', deployed.markets.bookAdapter);
    console2.log('GiveRegistry', deployed.markets.giveRegistry);
    console2.log('GiveEscrow', deployed.markets.giveEscrow);
    console2.log('GiveAdapter', deployed.markets.giveAdapter);
    console2.log('Deployment file', path);
  }

  /// @notice Deploy the vault and the three products. `owner` must be the caller when this is not broadcast.
  function deployAll(
    address owner,
    address postman,
    address treasury,
    bool local,
    uint256 nativeMin,
    uint256 usdtMin,
    uint256 vettingFeeBPS,
    uint256 maxRelayFeeBPS
  ) public returns (All memory deployed) {
    _requireChain56();
    if (local) revert LocalDeploymentRefused();
    deployed.vault = deploy(owner, postman, USDT, false, nativeMin, usdtMin, vettingFeeBPS, maxRelayFeeBPS);
    deployed.ext = _mainnetExternals(treasury);
    deployed.product = _products(owner, deployed.vault.entrypoint, deployed.ext);
    deployed.markets = _markets(owner, deployed.vault.entrypoint, deployed.ext);
  }

  function _refuseUnconfirmedMainnet() internal view {
    if (block.chainid != 56 || !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
    if (keccak256(bytes(vm.envOr('CONFIRM_MAINNET', string('')))) != keccak256('yes')) {
      revert MainnetBroadcastRefused();
    }
  }

  function _assertMainnetCode() internal view {
    if (
      WBNB.code.length == 0 || USDT.code.length == 0 || PANCAKE_FACTORY.code.length == 0 || PANCAKE_NPM.code.length == 0
        || ANNOUNCER.code.length == 0 || REGISTRY.code.length == 0 || SANCTIONS_ORACLE.code.length == 0
        || BNB_USD.code.length == 0 || USDT_USD.code.length == 0 || BTCB.code.length == 0 || ETH_TOKEN.code.length == 0
    ) revert ExternalHasNoCode();
  }

  function _mainnetExternals(address treasury) internal pure returns (External memory ext) {
    ext = External({
      wbnb: WBNB,
      usdt: USDT,
      pancakeFactory: PANCAKE_FACTORY,
      positionManager: PANCAKE_NPM,
      announcer: ANNOUNCER,
      registry: REGISTRY,
      sanctionsOracle: SANCTIONS_ORACLE,
      bnbUsd: BNB_USD,
      usdtUsd: USDT_USD,
      treasury: treasury
    });
  }

  function _products(address owner, address entrypoint, External memory ext) internal returns (Product memory product) {
    (product.saleDeployer, product.launchFactory, product.launchAdapter) = _deployLaunch(owner, entrypoint, ext);
    product.hushSend = address(new HushSendAdapter(entrypoint, ext.announcer));
    product.gift = address(new GiftAdapter(entrypoint));
  }

  /// @dev Everything here is created straight from the broadcasting `owner` (no helper contract: a
  ///      helper would carry SealedBook's creation code and break the EIP-170 size limit). `owner`
  ///      links the adapter, lists the pairs, and is the deployer that wires Give once.
  function _markets(address owner, address entrypoint, External memory ext) internal returns (Markets memory m) {
    SealedBook book = new SealedBook(entrypoint, ext.wbnb, ext.usdt, ext.treasury, owner);
    BookAdapter adapter = new BookAdapter(entrypoint, address(book), ext.wbnb);
    book.setAdapter(address(adapter));
    m.book = address(book);
    m.bookAdapter = address(adapter);
    m.wbnb = _listPair(book, 'WBNB', ext.wbnb, ext.usdt, ext.bnbUsd, ext.usdtUsd, ext.pancakeFactory);
    m.btcb = _listPair(book, 'BTCB', BTCB, ext.usdt, BTC_USD, ext.usdtUsd, ext.pancakeFactory);
    m.eth = _listPair(book, 'ETH', ETH_TOKEN, ext.usdt, ETH_USD, ext.usdtUsd, ext.pancakeFactory);
    GiveRegistry registry = new GiveRegistry(ext.usdt);
    GiveEscrow escrow = new GiveEscrow(address(registry), entrypoint, ext.usdt);
    GiveAdapter giveAdapter = new GiveAdapter(entrypoint, address(escrow));
    registry.linkEscrow(address(escrow));
    escrow.linkAdapter(address(giveAdapter));
    m.giveRegistry = address(registry);
    m.giveEscrow = address(escrow);
    m.giveAdapter = address(giveAdapter);
  }

  function _listPair(
    SealedBook book,
    string memory symbol,
    address base,
    address quoteToken,
    address baseFeed,
    address quoteFeed,
    address factory
  ) internal returns (Pair memory pair) {
    pair.symbol = symbol;
    pair.base = base;
    pair.quoteToken = quoteToken;
    pair.tick = TICK;
    pair.lot = LOT;
    if (baseFeed.code.length != 0 && quoteFeed.code.length != 0) {
      uint32 baseHb = _heartbeat(baseFeed, string.concat(symbol, '_USD'));
      uint32 quoteHb = _heartbeat(quoteFeed, 'USDT_USD');
      pair.marketId = book.listChainlinkPair(base, TICK, LOT, baseFeed, quoteFeed, baseHb, quoteHb);
      pair.oracle = 'chainlink';
      pair.baseFeed = baseFeed;
      pair.quoteFeed = quoteFeed;
      console2.log(symbol, pair.oracle);
      console2.log('  market', pair.marketId);
      console2.log('  base heartbeat', uint256(baseHb));
      console2.log('  quote heartbeat', uint256(quoteHb));
      return pair;
    }
    address pool = _v3Pool(factory, base, quoteToken);
    if (pool == address(0)) revert MissingReference(symbol);
    pair.marketId = book.listTwapPair(base, TICK, LOT, pool);
    pair.oracle = 'twap';
    pair.pool = pool;
    console2.log(symbol, pair.oracle);
    console2.log('  market', pair.marketId);
    console2.log('  pool', pool);
  }

  /// @dev Heartbeat = `HEARTBEAT_<name>` if set, else 3600. Reverts (fails loudly) if the feed's latest round is
  ///      older than that heartbeat: listing a stale feed would make every crossing settle revert `StaleOracle`.
  function _heartbeat(address feed, string memory name) internal view returns (uint32 hb) {
    uint256 configured = vm.envOr(string.concat('HEARTBEAT_', name), uint256(HEARTBEAT));
    if (configured == 0 || configured > 1 days) revert StaleFeed(name, 0, configured);
    hb = uint32(configured);
    (,,, uint256 updatedAt,) = IChainlinkRound(feed).latestRoundData();
    uint256 age = updatedAt == 0 || updatedAt > block.timestamp ? type(uint256).max : block.timestamp - updatedAt;
    if (age > configured) revert StaleFeed(name, age, configured);
  }

  function _v3Pool(address factory, address base, address quoteToken) internal view returns (address pool) {
    if (factory.code.length == 0) return address(0);
    uint24[4] memory fees = [uint24(500), 2500, 100, 10_000];
    for (uint256 i = 0; i < fees.length; i++) {
      address found = IPancakeV3FactoryView(factory).getPool(base, quoteToken, fees[i]);
      if (found.code.length != 0) return found;
    }
    return address(0);
  }

  function _deployLaunch(
    address owner,
    address entrypoint,
    External memory ext
  ) internal returns (address saleDeployer, address factory, address adapter) {
    saleDeployer = address(new SaleDeployer());
    LaunchFactory.Deployment memory d;
    d.entrypoint = entrypoint;
    d.wbnb = ext.wbnb;
    d.usdt = ext.usdt;
    d.pancakeFactory = ext.pancakeFactory;
    d.positionManager = ext.positionManager;
    d.treasury = ext.treasury;
    d.saleDeployer = saleDeployer;
    d.bnbUnits = _bnbUnits();
    d.usdtUnits = _usdtUnits();
    LaunchFactory deployed = new LaunchFactory(owner, d);
    LaunchAdapter launchAdapter = new LaunchAdapter(entrypoint, address(deployed));
    deployed.setLaunchAdapter(address(launchAdapter));
    factory = address(deployed);
    adapter = address(launchAdapter);
  }

  function _bnbUnits() internal pure returns (uint256[5] memory units) {
    units[0] = 0.02 ether;
    units[1] = 0.1 ether;
    units[2] = 0.5 ether;
    units[3] = 2 ether;
    units[4] = 10 ether;
  }

  function _usdtUnits() internal pure returns (uint256[5] memory units) {
    units[0] = 20 ether;
    units[1] = 100 ether;
    units[2] = 500 ether;
    units[3] = 2000 ether;
    units[4] = 10_000 ether;
  }

  function _writeDeployment(uint256 startBlock, All memory d) internal returns (string memory path) {
    path = string.concat('deployments/', vm.toString(block.chainid), '.json');
    vm.writeFile(path, '{\n');
    _line(path, _jsonUint('chainId', block.chainid, true));
    _line(path, _jsonAddr('entrypoint', d.vault.entrypoint, true));
    _writePools(path, d.vault.nativePool, d.vault.nativeScope, d.vault.usdtPool, d.vault.usdtScope, d.ext.usdt);
    _line(path, _jsonAddr('hushSend', d.product.hushSend, true));
    _line(path, _jsonAddr('gift', d.product.gift, true));
    _line(path, _jsonAddr('launchFactory', d.product.launchFactory, true));
    _line(path, _jsonAddr('launchAdapter', d.product.launchAdapter, true));
    _line(path, _jsonAddr('book', d.markets.book, true));
    _line(path, _jsonAddr('bookAdapter', d.markets.bookAdapter, true));
    _writePairs(path, d.markets);
    _line(path, _jsonAddr('giveRegistry', d.markets.giveRegistry, true));
    _line(path, _jsonAddr('giveEscrow', d.markets.giveEscrow, true));
    _line(path, _jsonAddr('giveAdapter', d.markets.giveAdapter, true));
    _line(path, _jsonAddr('announcer', d.ext.announcer, true));
    _line(path, _jsonAddr('registry', d.ext.registry, true));
    _line(path, _jsonAddr('sanctionsOracle', d.ext.sanctionsOracle, true));
    _writeFeeds(path, d.ext.bnbUsd, d.ext.usdtUsd);
    _line(path, _jsonUint('startBlock', startBlock, false));
    vm.writeLine(path, '}');
  }

  function _writePools(
    string memory path,
    address nativePool,
    uint256 nativeScope,
    address usdtPool,
    uint256 usdtScope,
    address usdt
  ) internal {
    _line(path, '  "pools": {');
    _line(path, _poolLine('BNB', nativePool, nativeScope, Constants.NATIVE_ASSET, true));
    _line(path, _poolLine('USDT', usdtPool, usdtScope, usdt, false));
    _line(path, '  },');
  }

  function _writePairs(string memory path, Markets memory m) internal {
    _line(path, '  "bookPairs": [');
    _writePair(path, m.wbnb, true);
    _writePair(path, m.btcb, true);
    _writePair(path, m.eth, false);
    _line(path, '  ],');
  }

  function _writePair(string memory path, Pair memory p, bool comma) internal {
    _line(path, '    {');
    _line(path, string.concat('      "symbol": "', p.symbol, '",'));
    _line(path, string.concat('      "marketId": "', vm.toString(p.marketId), '",'));
    _line(path, string.concat('      "base": "', vm.toString(p.base), '",'));
    _line(path, string.concat('      "quote": "', vm.toString(p.quoteToken), '",'));
    _line(path, string.concat('      "oracle": "', p.oracle, '",'));
    _line(path, string.concat('      "baseFeed": "', vm.toString(p.baseFeed), '",'));
    _line(path, string.concat('      "quoteFeed": "', vm.toString(p.quoteFeed), '",'));
    _line(path, string.concat('      "pool": "', vm.toString(p.pool), '",'));
    _line(path, string.concat('      "tick": "', vm.toString(p.tick), '",'));
    _line(path, string.concat('      "lot": "', vm.toString(p.lot), '"'));
    _line(path, comma ? '    },' : '    }');
  }

  function _writeFeeds(string memory path, address bnbUsd, address usdtUsd) internal {
    _line(
      path,
      string.concat('  "feeds": {"BNB_USD": "', vm.toString(bnbUsd), '", "USDT_USD": "', vm.toString(usdtUsd), '"},')
    );
  }

  function _poolLine(
    string memory name,
    address pool,
    uint256 scope,
    address asset,
    bool comma
  ) internal view returns (string memory) {
    return string.concat(
      '    "',
      name,
      '": {"pool": "',
      vm.toString(pool),
      '", "scope": "',
      vm.toString(scope),
      '", "asset": "',
      vm.toString(asset),
      comma ? '"},' : '"}'
    );
  }

  function _jsonAddr(string memory key, address value, bool comma) internal view returns (string memory) {
    return string.concat('  "', key, '": "', vm.toString(value), comma ? '",' : '"');
  }

  function _jsonUint(string memory key, uint256 value, bool comma) internal view returns (string memory) {
    return string.concat('  "', key, '": ', vm.toString(value), comma ? ',' : '');
  }

  function _line(string memory path, string memory line) internal {
    vm.writeLine(path, line);
  }
}
