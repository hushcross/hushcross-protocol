# Vault

The Vault holds BNB and USDT in separate Privacy Pools. A deposit creates a private spending note; a withdrawal proves knowledge of that note and membership in the current approved association set without naming the original deposit being spent.

This page describes the contracts in this source-available repository. The public website currently runs in demonstration mode. A deployed contract and a displayed example balance are not evidence that a website action is live.

## Components and amounts

The deployment uses an Entrypoint proxy, a native-asset pool and a token pool. The Entrypoint collects the vetting fee and forwards the net amount to the relevant pool. See [DeployVault](../../contracts/script/DeployVault.s.sol), [Entrypoint](../../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/Entrypoint.sol) and [PrivacyPool](../../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/PrivacyPool.sol).

| Parameter | Source-defined default or policy | Where to verify |
|---|---|---|
| Vetting fee | 30 basis points, or 0.30%, per deposit | `DeployAll.run` defaults; live `Entrypoint.assetConfig` can differ |
| Relay-fee ceiling | 150 basis points, or 1.50%, in the deployment defaults | `DeployAll.run`; live `assetConfig.maxRelayFeeBPS` |
| Minimum gross deposit | 0.02 BNB or 20 USDT in the deployment defaults | `DeployAll.run`; `Entrypoint._handleDeposit` checks the gross amount before deducting the fee |
| Standard net BNB amounts | 0.02, 0.1, 0.5, 2, 10 | Product policy; `BookTypes.bnbUnits` and `DeployAll._bnbUnits` encode the same amounts for module refunds/configuration |
| Standard net USDT amounts | 20, 100, 500, 2,000, 10,000 | Product policy; `BookTypes.usdtUnits` and `DeployAll._usdtUnits` |

Sources: [DeployAll](../../contracts/script/DeployAll.s.sol), [BookTypes](../../contracts/src/book/BookTypes.sol). Standard amounts reduce distinctive amount patterns; they are **not a denomination restriction enforced by the base pool's withdrawal function**. Module refund routines use these amounts when constructing replacement notes.

To create a net note worth `u`, a client or refund routine accounts for the deposit fee:

```text
gross(u) = floor((u - 1) × 10000 / (10000 - feeBps)) + 1
```

This is the integer fee inverse in [LaunchClearing.grossForNet](../../contracts/src/launch/LaunchClearing.sol). Read the current fee, not an assumed permanent default. Re-depositing a refund or gift incurs the then-current vetting fee again.

## Deposit and withdraw

1. Generate and retain the note secrets and precommitment locally. Recovery-phrase generation, browser encryption and backup formats are client responsibilities, not contract-enforced settings.
2. Submit BNB or approved USDT to the Entrypoint. The depositor, amount, pool, commitment, label and timing are public.
3. Screen determines whether a deposit label belongs in its approved set. An authorized postman publishes that set's root to the Entrypoint.
4. Construct a withdrawal proof using a known pool-state root and the **latest** association root. The proof binds the pool scope, processing contract and encoded withdrawal instructions.
5. Submit through the relevant processing contract, directly or through a relay. A successful withdrawal consumes a nullifier and inserts a new commitment for the remaining note state.

The checks are in `PrivacyPool.validWithdrawal` and `withdraw`; the authorized root update is `Entrypoint.updateRoot`. An association-root change can make an already-built proof stale. A relay pays execution Gas on behalf of the user; it does not remove the proof requirements or make the recipient and payout amount secret.

## Exit paths and failures

- **Normal withdrawal:** needs a valid proof against the latest approved root. A rejected proof, stale root or failed adapter transfer reverts the transaction; a mined revert can still cost Gas.
- **Direct depositor exit:** `PrivacyPool.ragequit` requires the original depositor address recorded for the label, a valid commitment proof and an unspent commitment. It sends funds to that depositor and publicly links the exit. Knowing a note's secrets does not by itself grant this caller identity.
- **Contract-created notes:** GiftAdapter, SealedSale, SealedBook and GiveEscrow can deposit replacement notes. Those contracts become the recorded depositors and expose no ragequit forwarding function. Once the replacement note has entered the pool, its holder depends on continued inclusion in the latest approved root; there is no separate on-chain exit through those contracts.
- **Wind-down:** the pool's `dead` flag stops new deposits. It does not remove the ordinary withdrawal checks or create an exit for contract-created notes.

The pool's latest-root rule does not require a particular website. If a note is already included and the necessary tree/proof data is available, an independent client can construct and submit a valid proof. It cannot invent approval for a label missing from the latest set.

Read [privacy](../privacy.md) and [trust and risks](../trust-and-risks.md) before relying on any exit path.
