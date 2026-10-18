# Frequently asked questions

## Is the website live with real balances?

As of 18 October 2026, the public [HushCross website](https://hushcross.fun) is a demo with sample data and a demo banner. Current protocol contracts are separately deployed on BSC mainnet. A displayed sample balance, order or completion screen is not evidence of a real transaction. Use the [deployment table](../README.md) and [verification guide](verify.md) to identify the contracts.

## What is published here?

Contract source and explanatory documentation, not the website, client application or backend services. This is a **source-available** release. First-party contracts use **BUSL-1.1**, with a **2028-10-18** change date to **GPL-2.0-or-later** under the license terms. Documentation uses **CC BY 4.0**; dependencies retain their original licenses. Source visibility does not establish security assurance or unrestricted permission to use every component commercially.

## Does HushCross hide every transaction detail?

No. Privacy Pools proofs avoid identifying the source deposit used for a private withdrawal. Deposits, public destinations, amounts, timing, contract interactions and many event fields remain visible. A small anonymity set, distinctive amounts, linked addresses or network metadata can make correlation easier. One-time addresses and standard amounts do not eliminate those risks. Read [privacy](privacy.md).

## Who holds the keys? Can support restore my account?

The client design derives keys locally and encrypts stored wallet material with a supported passkey-derived key or a password-derived key. Keep the recovery phrase and any necessary encrypted backups and passwords independently available. Support does not have a recovery copy of your private keys. Device migration must not assume that every passkey or browser storage entry will automatically transfer.

This is a key-handling statement, not a guarantee about contract administration: Entrypoint is upgradeable, and privileged roles can affect system behavior. See [architecture](architecture.md).

## Why use standard amounts and wait before spending?

Unusual amounts and closely timed deposits and withdrawals are easier to correlate. Standard net note amounts and waiting for other activity can reduce those clues. The client's Good / Fair / Weak assessment is guidance, not a probability of anonymity, a guarantee or an on-chain eligibility rule. The applicable fees and gas requirements still matter.

## Is an approved deposit immediately spendable?

Not necessarily. Private withdrawal needs an inclusion path for a label in the **latest on-chain association root**, along with valid pool state and a valid proof. A service saying that a deposit is approved is different from the postman publishing the corresponding root. Changes to the root can require a fresh proof.

## Can I always use ragequit if Screen is unavailable?

No. The pool's `ragequit` function is restricted to the original depositor and requires a valid proof for the current note state. A user who directly deposited from an address they control may use that public route; it reveals the exit's connection to the original depositor.

For notes successfully deposited by **GiftAdapter, SealedSale, SealedBook or GiveEscrow**, the original depositor is the contract. These contracts do not expose ragequit on the user's behalf. Those notes depend on Screen approval and root publication; knowing their secrets alone does not provide another on-chain exit. Pool wind-down does not change who the original depositor is.

## Does a successful refund mean I can bypass approval?

No. A refund that successfully opens new vault notes has created new contract-originated deposits. They still need approval and the appropriate published root before private spending.

Some **unclaimed escrow** has a direct-payout alternative: SealedSale has a recipient-only `claimToPayout`, and SealedBook restricts `claimToRecipient` to the recipient for vault-funded orders. Refund helpers also handle certain failed deposit attempts by paying the affected amount to the recorded payout address. These alternatives do not recover a note that was already deposited successfully. They are public payments and have different privacy consequences. See [contracts](contracts.md).

## What can the relay see?

The relay sees the request, destination, amount, fee, public proof, scheduling information and network metadata. It does not need the wallet's private signing keys or note witness to submit a completed proof. If you delegate reveal, the relay receives the information needed to open that bid or order; encryption in transit or in a task envelope does not make its contents permanently secret from the designated decrypting service.

If a relay response is missing, first inspect the job and transaction state. Do not assume the request failed or submit a conflicting operation blindly.

## What if I lose the reveal information?

Launch and Book commitments require their preimages. A recovery phrase alone is not a promise that every locally generated bid salt, order setting or pending task can be reconstructed. Keep the relevant backup and reveal data until the action is finalized and claimed. Late-reveal or unrevealed-claim functions still require the necessary preimage and must satisfy their contract conditions.

## Are Book orders completely hidden before reveal?

No. `commit` exposes the market, side and escrow amount. The commitment protects the specified preimage terms, including the limit price and quantity, until reveal; escrow can itself provide clues about them. Revealed orders and the clearing result are public. A contract-carried order remains already revealed; making a new sealed commitment is a different action.

## Is a gift link safe to post publicly? Does expiry prevent claims?

A complete gift link contains a spending secret. Anyone who obtains it, including a recipient who forwards it, can attempt to claim available notes. A group-link interface cannot enforce one share per human, and the sender retains recovery capability if they retained the secret.

The URL fragment is excluded from ordinary HTTP requests, but it is available to client-side code and anyone holding the full link. Avoid exposing it in screenshots, shared logs or untrusted pages. The application's expiry/reclaim workflow is not a recipient-only permission or a hard expiry check in GiftAdapter.

## Where do sale, trading and giving refunds go?

- **Launch:** public-wallet bids receive ordinary refunds; eligible unused escrow from vault-funded bids can be split into vault notes and a public remainder. A failed sale does not create a winning token allocation.
- **Book:** fill proceeds always go to the recorded recipient. Only eligible unused escrow from the order's own vault-funded contribution is returned to the vault. Counterparty proceeds are not routed into fresh notes by that claim.
- **Give:** tips are immediate payments. A settled failed goal permits each recorded donation to be refunded according to whether it was publicly or vault funded.

Refund accounting is not a promise to restore previously paid gas or relay fees. Creating refund notes can also incur the current vault deposit fee. See the [module guides](overview.md#six-features).

## Does a missing logo or unavailable indexer change the contract?

No. A sale profile must match its on-chain content hash; otherwise the display should fall back to neutral branding. The indexer presents public chain data but does not determine settlement or ownership. Contract state can be checked independently, although doing so requires suitable tooling and an RPC with adequate historical coverage. See the [service table](architecture.md#hosted-services).

## Does source verification prove safety?

It establishes a relationship between source, compiler settings and deployed code when independently checked. It does not prove that the mechanism is free of flaws, that a future proxy implementation will be unchanged, that services will stay online or that privacy will hold for a particular transaction.

Documentation: **CC BY 4.0**. See the [README](../README.md) for license terms and current deployment references.

Delegated-reveal privacy boundary: the entrusted relay can decrypt the submitted preimage **before the reveal window**. Delaying its broadcast is an operational schedule, not a cryptographic time lock.
