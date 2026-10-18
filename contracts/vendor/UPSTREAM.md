# Pinned contract sources and licenses

## Privacy Pools source snapshot

| Item | Pinned value |
| --- | --- |
| Repository | https://github.com/0xbow-io/privacy-pools-core |
| Release tag | `v1.3.0` |
| Commit | `c312dcd58f6ad085204be61923c49f8065e4e9ae` |
| Recorded upstream tree | `d0bf7419f9e250ec1f3ded013cd1290edba208e6` |

This directory contains the unmodified Solidity dependency closure used by the HushCross contracts and deployment scripts, rather than the whole upstream repository. Original source paths under `privacy-pools-core/packages/contracts/src` are retained. Upstream tests, deployment scripts, unrelated contracts, reports and application packages are not included.

### Included licenses

- The included Entrypoint, PrivacyPool, State, pool implementations, Constants, ProofLib and interfaces retain their **Apache-2.0** headers and `Copyright 2025 0XBOW LTD` notices. The upstream root [LICENSE](privacy-pools-core/LICENSE) and contracts-package [LICENSE](privacy-pools-core/packages/contracts/LICENSE) are reproduced unchanged. The recorded upstream snapshot contains no NOTICE file.
- `contracts/verifiers/WithdrawalVerifier.sol` and `contracts/verifiers/CommitmentVerifier.sol` retain the original **`GPL-3.0` SPDX identifier**, `Copyright 2021 0KIMS association`, and the notice granting GPL version 3 or later. The complete [GNU GPL version 3](../../licenses/GPL-3.0.txt) is included. These files are not relicensed under HushCross's BUSL terms.
- The unreferenced `interfaces/external/ICreateX.sol` (`AGPL-3.0-only`), `BatchRelayer.sol`, `IBatchRelayer.sol` and `DeployLib.sol` are not part of this selected source closure.

`DeployVault.s.sol` retains imports of both verifier sources solely as compilation inputs for their separate artifacts. It deploys them using forge-std's `deployCode('WithdrawalVerifier.sol:WithdrawalVerifier')` and `deployCode('CommitmentVerifier.sol:CommitmentVerifier')`, which load artifact creation code with `vm.getCode` and deploy it with `CREATE`. The script does not instantiate the verifier Solidity types with `new` or reference their `type(...).creationCode`. Third-party verifier sources and artifacts retain their original GPL terms; HushCross's BUSL license does not replace those terms. This technical separation is not a legal compatibility guarantee.

## Exact build dependencies

| Dependency | Required version / revision | License | Source |
| --- | --- | --- | --- |
| `@openzeppelin/contracts` | `5.1.0` | MIT | https://github.com/OpenZeppelin/openzeppelin-contracts |
| `@openzeppelin/contracts-upgradeable` | `5.0.2` | MIT | https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable |
| `@zk-kit/lean-imt.sol` | `2.0.0` | MIT | https://github.com/privacy-scaling-explorations/zk-kit.solidity |
| `poseidon-solidity` | `0.0.5` | MIT | https://github.com/vimwitch/poseidon-solidity |
| `forge-std` | `v1.9.6`, commit `3b20d60d14b343ee4f908cb8079495c07f5e8981` | Apache-2.0 OR MIT | https://github.com/foundry-rs/forge-std |

The npm versions and tarball integrity hashes are pinned in `contracts/package-lock.json`. Install from the `contracts` directory using the lockfile; `.npmrc` keeps lifecycle scripts disabled and enables legacy peer resolution for the exact upstream combination of OpenZeppelin contracts 5.1.0 and upgradeable 5.0.2. Do not silently change either version to satisfy the latter's 5.0.2 peer declaration.

The `lean-imt/` remapping uses `lib/lean-imt/`. After installing the locked npm packages, create the relative build-only link with `ln -s ../node_modules/@zk-kit/lean-imt.sol lib/lean-imt` from `contracts/`. This avoids a directory-name normalization issue with the recorded toolchain; the link never points outside this checkout. Place a checkout of the exact `forge-std` commit above in `contracts/lib/forge-std` before compiling. Its source and its `LICENSE-APACHE` and `LICENSE-MIT` remain upstream dependencies and are not bundled here. Do not substitute an unpinned default branch or install the entire Privacy Pools monorepo dependency set.

Preserve the compiler settings in `contracts/foundry.toml`: Solidity 0.8.28, Cancun, optimizer enabled with 200 runs, no bytecode metadata hash, and no CBOR metadata trailer. Dependency source and license files must remain intact when installed or redistributed.
