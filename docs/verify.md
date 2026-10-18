# Build and verify the published contracts

This check compares newly compiled **runtime** bytecode with BSC chain data. It does not deploy, sign, spend gas, inspect a wallet, or establish that a contract is safe. Use a trusted RPC and independently confirm the public contract addresses.

## Toolchain

The comparison was prepared with Foundry `1.7.1` (commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`), Solidity **0.8.28+commit.7893614a**, Cancun EVM, optimizer enabled with **200** runs, no via-IR, `bytecode_hash = "none"` and `cbor_metadata = false`. These settings are in [foundry.toml](../contracts/foundry.toml). Python 3.10 or later runs the read-only comparison tool. Node/npm installs build dependencies only.

| Dependency | Fixed version / revision |
|---|---|
| Privacy Pools source subset | `c312dcd58f6ad085204be61923c49f8065e4e9ae` (`v1.3.0`) |
| forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` (`v1.9.6`) |
| OpenZeppelin contracts | `5.1.0` |
| OpenZeppelin upgradeable | `5.0.2` |
| lean-imt.sol | `2.0.0` |
| poseidon-solidity | `0.0.5` |

See [package-lock.json](../contracts/package-lock.json) for npm archive integrity hashes and [UPSTREAM](../contracts/vendor/UPSTREAM.md) for provenance and separate license terms. The retained dependency combination has a peer-version mismatch: upgradeable 5.0.2 declares contracts 5.0.2 as its peer, while this build uses contracts 5.1.0. **Do not silently change versions.** The install below uses the locked combination with legacy peer resolution, and disables lifecycle scripts. This is not a statement that arbitrary dependency combinations are compatible.

## Rebuild from a clean checkout

Install Foundry from its [official installation documentation](https://getfoundry.sh/introduction/installation/) and ensure Solidity 0.8.28 is available before using offline mode. Do not run deployment scripts for verification.

From the repository root:

```sh
cd contracts
npm ci --ignore-scripts --legacy-peer-deps --no-audit --no-fund
mkdir -p lib
# Run in a clean checkout: the following destination must not already exist.
git clone --no-checkout https://github.com/foundry-rs/forge-std.git lib/forge-std
git -C lib/forge-std checkout --detach 3b20d60d14b343ee4f908cb8079495c07f5e8981
git -C lib/forge-std rev-parse HEAD
ln -s ../node_modules/@zk-kit/lean-imt.sol lib/lean-imt
forge build --force --offline --ast
cd ..
python3 tools/verify_bytecode.py --json "${TMPDIR:-/tmp}/hushcross-bytecode.json"
```

The relative lean-imt link is intentional: mapping directly to a directory whose name ends in `.sol` produced a concatenated import path with the recorded toolchain. No dependency is copied into the published source subset. Local dependencies, cache and artifacts are ignored by Git.

A compiler warning or lint warning is not automatically a mismatch, and a successful build is not a security assessment. The supplied deployment sources target chain 56 / chain-56 fork environments and reject mock deployment. The original explicit mainnet-broadcast guard remains in `DeployAll`, while standalone `DeployVault.run` refuses chain-56 broadcasting. The deployment scripts were **not executed** as part of this comparison.

## What the verifier checks

[`tools/verify_bytecode.py`](../tools/verify_bytecode.py) reads the mainnet table in the English README. It checks the chain ID, chooses one numbered snapshot block, and uses only `eth_call`, `eth_getCode`, `eth_getStorageAt` and block/chain reads.

1. Load the fresh compiler AST, runtime templates and compiler-reported immutable/link references. Require the recorded compiler and settings.
2. Compare the Entrypoint **proxy** against the proxy artifact; resolve its EIP-1967 implementation slot and compare that implementation separately.
3. Check immutable bytes against the contract getters and independent known deployment bindings. Recompute each pool's `SCOPE` from its address, chain ID and asset using the upstream constructor formula. The UUPS implementation self-address is checked explicitly. Unknown immutable kinds fail rather than being ignored.
4. Read library targets from the compiler-described link slots, require repeated references to agree, and compare **each referenced library's own runtime** recursively. Library self-address guards are checked, not discarded.
5. Compare every remaining runtime byte, with no arbitrary byte masking and no metadata stripping. The build disables appended CBOR metadata. Re-read the chosen block to reject a changed block hash.

The [comparison table](bytecode-verification.md) records the actual snapshot, addresses, sizes and result. Library addresses are contract dependencies, not a list of operator wallets. A successful result proves this specific code comparison under the trust placed in the RPC; it does not prove current service availability, future upgrades, owner behavior, correct economics or the absence of defects.

The verifier does **not** reconstruct historical creation transactions, re-check source text hosted by an explorer, or compare every dynamically created sale/token/vesting instance. `SaleDeployer` includes the sale creation template and is checked as a deployed contract, but this is not an instance-by-instance history check. External oracles, routers and standard singleton contracts are outside the reported code set.

## Manual checks and explorer cross-check

Use a numbered block from the report, rather than mixing `latest` reads:

```sh
cast code <public-contract-address> --block <snapshot-block> --rpc-url https://bsc-dataseed.bnbchain.org
cd contracts
forge inspect <source-path>:<contract-name> deployedBytecode
```

Raw string equality is insufficient when an artifact contains library placeholders or constructor immutables. Inspect `out/<source>/<contract>.json` for `deployedBytecode.linkReferences` and `immutableReferences`, and resolve them using the procedure above.

Follow each README address's BscScan **Contract / Code** link. Compare compiler version, optimizer/EVM settings, source files, library bindings and constructor arguments shown there. If an explorer has not supplied a complete match, or your local code differs, record that limitation rather than replacing a failed check with an explorer badge.

## Verification does not require production-use permission

The original HushCross code is source-available under BUSL-1.1 before the Change Date; consult [the license](../contracts/LICENSE) for the non-production grant and restrictions. Verifier sources, standard references and dependencies retain their own terms. The two GPL verifiers are built independently; deployment tooling reads their artifacts rather than embedding their creation bytecode into the first-party deployment artifact. This technical separation does not relicense those files or replace a legal review of a proposed redistribution or deployment.
