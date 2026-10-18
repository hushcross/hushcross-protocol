// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';

import {Entrypoint} from 'contracts/Entrypoint.sol';
import {PrivacyPoolComplex} from 'contracts/implementations/PrivacyPoolComplex.sol';
import {PrivacyPoolSimple} from 'contracts/implementations/PrivacyPoolSimple.sol';
import {Constants} from 'contracts/lib/Constants.sol';
// Build inputs only: compile the GPL verifiers into separate artifacts. Deployment loads
// those artifacts with deployCode instead of embedding their creation code through `new`.
import {CommitmentVerifier} from 'contracts/verifiers/CommitmentVerifier.sol';
import {WithdrawalVerifier} from 'contracts/verifiers/WithdrawalVerifier.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/// @title DeployVault
/// @notice Deploys an Entrypoint proxy, the native pool, one token pool, and the upstream verifiers.
/// @dev Supports chain 56 only. Every address and parameter is read from the environment.
/// Refuses `--broadcast` when `block.chainid` is 56 so a mainnet RPC cannot be targeted by accident.
/// A fork rehearsal is a dry run (`chainid` 56, no broadcast) and is allowed.
///
/// Environment:
/// - `OWNER_ADDRESS` — broadcast sender and `OWNER_ROLE`
/// - `POSTMAN_ADDRESS` — `ASP_POSTMAN`
/// - `VETTING_FEE_BPS` — spec value 30
/// - `MAX_RELAY_FEE_BPS` — spec value 150
/// - `NATIVE_MIN_DEPOSIT` — smallest BNB unit, 0.02 ether, checked against the gross deposit
/// - `USDT_MIN_DEPOSIT` — smallest USDT unit, 20e18
/// - `DEPLOY_MOCK_USDT` — retained for compatibility; true is rejected
/// - `USDT_ADDRESS` — required; an existing BSC-USD contract on chain 56 or its fork
contract DeployVault is Script {
  struct Result {
    address implementation;
    address entrypoint;
    address withdrawalVerifier;
    address ragequitVerifier;
    address nativePool;
    address usdt;
    address usdtPool;
    uint256 nativeScope;
    uint256 usdtScope;
  }

  error MainnetBroadcastRefused();
  error UsdtHasNoCode();
  error UnsupportedChain();
  error LocalDeploymentRefused();

  /// @notice Read the environment, deploy, and print every address plus both pool scopes.
  function run() external virtual {
    _requireChain56();
    if (block.chainid == 56 && vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) revert MainnetBroadcastRefused();

    address owner = vm.envAddress('OWNER_ADDRESS');
    address postman = vm.envAddress('POSTMAN_ADDRESS');
    uint256 vettingFeeBPS = vm.envUint('VETTING_FEE_BPS');
    uint256 maxRelayFeeBPS = vm.envUint('MAX_RELAY_FEE_BPS');
    uint256 nativeMin = vm.envUint('NATIVE_MIN_DEPOSIT');
    uint256 usdtMin = vm.envUint('USDT_MIN_DEPOSIT');
    bool deployMock = vm.envOr('DEPLOY_MOCK_USDT', false);
    if (deployMock) revert LocalDeploymentRefused();
    address usdt = vm.envAddress('USDT_ADDRESS');

    vm.startBroadcast(owner);
    Result memory deployed = deploy(owner, postman, usdt, deployMock, nativeMin, usdtMin, vettingFeeBPS, maxRelayFeeBPS);
    vm.stopBroadcast();

    console2.log('Chain id', block.chainid);
    console2.log('Owner', owner);
    console2.log('Postman', postman);
    console2.log('Vetting fee bps', vettingFeeBPS);
    console2.log('Max relay fee bps', maxRelayFeeBPS);
    console2.log('Native min deposit', nativeMin);
    console2.log('USDT min deposit', usdtMin);
    console2.log('Entrypoint implementation', deployed.implementation);
    console2.log('Entrypoint proxy', deployed.entrypoint);
    console2.log('Withdrawal verifier', deployed.withdrawalVerifier);
    console2.log('Ragequit verifier', deployed.ragequitVerifier);
    console2.log('Native pool', deployed.nativePool);
    console2.log('Native SCOPE', deployed.nativeScope);
    console2.log('USDT', deployed.usdt);
    console2.log('USDT pool', deployed.usdtPool);
    console2.log('USDT SCOPE', deployed.usdtScope);
  }

  /// @notice Deploy the vault and register both pools. Caller must be `owner` (or this contract, in tests).
  function deploy(
    address owner,
    address postman,
    address usdt,
    bool deployMock,
    uint256 nativeMin,
    uint256 usdtMin,
    uint256 vettingFeeBPS,
    uint256 maxRelayFeeBPS
  ) public returns (Result memory deployed) {
    _requireChain56();
    if (deployMock) revert LocalDeploymentRefused();
    address withdrawalVerifier = deployCode('WithdrawalVerifier.sol:WithdrawalVerifier');
    address ragequitVerifier = deployCode('CommitmentVerifier.sol:CommitmentVerifier');
    (address implementation, Entrypoint entrypoint) = _deployEntrypoint(owner, postman);
    PrivacyPoolSimple nativePool =
      _registerNative(entrypoint, withdrawalVerifier, ragequitVerifier, nativeMin, vettingFeeBPS, maxRelayFeeBPS);
    address token = _resolveUsdt(usdt, deployMock);
    PrivacyPoolComplex usdtPool =
      _registerToken(entrypoint, withdrawalVerifier, ragequitVerifier, token, usdtMin, vettingFeeBPS, maxRelayFeeBPS);
    deployed = _result(
      implementation,
      address(entrypoint),
      withdrawalVerifier,
      ragequitVerifier,
      address(nativePool),
      token,
      address(usdtPool),
      nativePool.SCOPE(),
      usdtPool.SCOPE()
    );
  }

  function _deployEntrypoint(
    address owner,
    address postman
  ) internal returns (address implementation, Entrypoint entrypoint) {
    implementation = address(new Entrypoint());
    ERC1967Proxy proxy = new ERC1967Proxy(implementation, abi.encodeCall(Entrypoint.initialize, (owner, postman)));
    entrypoint = Entrypoint(payable(address(proxy)));
  }

  function _registerNative(
    Entrypoint entrypoint,
    address withdrawalVerifier,
    address ragequitVerifier,
    uint256 minimum,
    uint256 vettingFeeBPS,
    uint256 maxRelayFeeBPS
  ) internal returns (PrivacyPoolSimple pool) {
    pool = new PrivacyPoolSimple(address(entrypoint), withdrawalVerifier, ragequitVerifier);
    entrypoint.registerPool(IERC20(Constants.NATIVE_ASSET), pool, minimum, vettingFeeBPS, maxRelayFeeBPS);
  }

  function _resolveUsdt(address usdt, bool deployMock) internal returns (address token) {
    if (deployMock) revert LocalDeploymentRefused();
    token = usdt;
    if (token.code.length == 0) revert UsdtHasNoCode();
  }

  function _requireChain56() internal view {
    if (block.chainid != 56) revert UnsupportedChain();
  }

  function _registerToken(
    Entrypoint entrypoint,
    address withdrawalVerifier,
    address ragequitVerifier,
    address token,
    uint256 minimum,
    uint256 vettingFeeBPS,
    uint256 maxRelayFeeBPS
  ) internal returns (PrivacyPoolComplex pool) {
    pool = new PrivacyPoolComplex(address(entrypoint), withdrawalVerifier, ragequitVerifier, token);
    entrypoint.registerPool(IERC20(token), pool, minimum, vettingFeeBPS, maxRelayFeeBPS);
  }

  function _result(
    address implementation,
    address entrypoint,
    address withdrawalVerifier,
    address ragequitVerifier,
    address nativePool,
    address token,
    address usdtPool,
    uint256 nativeScope,
    uint256 usdtScope
  ) internal pure returns (Result memory deployed) {
    deployed = Result({
      implementation: implementation,
      entrypoint: entrypoint,
      withdrawalVerifier: withdrawalVerifier,
      ragequitVerifier: ragequitVerifier,
      nativePool: nativePool,
      usdt: token,
      usdtPool: usdtPool,
      nativeScope: nativeScope,
      usdtScope: usdtScope
    });
  }
}
