# Trust and risks

HushCross's contracts enforce proofs, commitments, accounting and particular payout rules. They do not eliminate dependence on the client, approved-set publisher, chain, token contracts, price references or transaction execution.

The public website currently runs in demonstration mode. Deployed contracts, verified source records and example interface data are different things. This source-available release contains contract code and documentation; the operational web application and service implementations are not part of this release. Source availability is not a guarantee of safety, uninterrupted access, anonymity or financial outcomes.

## Contract-created notes have no ragequit route

This limitation applies after **GiftAdapter, SealedSale, SealedBook or GiveEscrow successfully deposits a replacement note into a Vault pool**.

[Entrypoint._handleDeposit](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/Entrypoint.sol) records its caller as the pool's depositor. [PrivacyPool.ragequit](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/PrivacyPool.sol) requires that original depositor to call, together with a valid commitment proof. The module, not the human holding the note secrets, is therefore the authorized caller. The module contracts expose no ragequit-forwarding function.

Consequences:

- A holder cannot bypass missing Screen approval or publication simply by knowing the replacement note's secrets.
- If the label never enters the latest approved set, or is removed from it, there is no separate module-provided on-chain exit for that note.
- Screen's handling of eligible recycled deposits and the postman's root publication are important availability/trust dependencies. An off-chain policy is not an unconditional withdrawal entitlement enforced by the pool.
- A direct public depositor can use its own depositor-only ragequit path with the required proof, but this is a public exit and does not transfer to a gift recipient merely because that person received the secret.

[Launch.claimToPayout](../contracts/src/launch/SealedSale.sol) and [Book.claimToRecipient](../contracts/src/book/SealedBook.sol) allow particular direct-payout choices **before** replacement deposits. Refund-to-dust fallbacks also operate before a successful deposit. None recovers a note already re-deposited by a module.

## Latest-root dependence

`PrivacyPool.validWithdrawal` accepts the Entrypoint's **latest** association root, not any historical approved root. A root update can make an in-flight proof unusable and may require fresh association data and a new proof.

Loss of the official Screen HTTP endpoint is not by itself proof that every already-approved note is inaccessible: an independent client with the latest necessary data may still generate a valid withdrawal. Conversely, obtaining state logs or another RPC endpoint cannot create association approval that the latest root does not contain.

Wind-down stops new deposits in the pool; it does not remove its proof/root requirements. See [Vault](modules/vault.md).

## Concentrated administrative powers

The [Entrypoint](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/Entrypoint.sol) owner role can authorize upgrades, manage privileged roles, register/remove pools, change deposit minimums and fee configuration, wind down deposits and withdraw accumulated vetting fees. An upgrade can change the behavior users rely on.

[LaunchFactory](../contracts/src/launch/LaunchFactory.sol) has an owner-controlled treasury setting for newly configured sales and a one-time adapter registration. Each sale receives its own treasury configuration at creation. [SealedBook](../contracts/src/book/SealedBook.sol) has owner-controlled market listing, minimum escrows and one-time adapter registration, with a two-step ownership transfer.

The deployment wiring can assign multiple roles to the same owner. Do not infer a multisignature arrangement, an upgrade delay or a mandatory timelock from the existence of role names or a two-step transfer. Verify live ownership, roles and proxy implementation before relying on a particular governance arrangement. This repository does not claim that every contract is upgradeable; the Entrypoint's upgrade authority is a specific, consequential permission.

## Off-chain services

| Component | Trust or availability boundary | What an outage does not imply |
|---|---|---|
| RPC / proxy | Supplies chain state, history and transaction transport; sees requested public data and network metadata | Another RPC can provide data, but cannot waive a proof, approval, contract deadline or authorization check |
| Screen and postman | Determine and publish the approved association set | Access to note secrets alone is not an exit for a module-created note missing from the latest set |
| Relay | Provides execution Gas, transaction submission and any optional delay, delegated reveal or stipend service | A submitted task is not a confirmed transaction; a top-up or timely reveal is not guaranteed merely by requesting it |
| Indexer | Provides activity/search views that may lag or be incomplete | A missing record is not evidence of failed execution or an unspent note |
| Metadata host | Serves sale profile documents and logos | A content hash checks bytes, not truth, endorsement or permanent availability |
| Monitoring | Observes failures and can notify operators | An alert does not settle an order, refund a campaign, publish a root or recover lost secrets |

Where the relevant function is permissionless, another caller can submit a valid reveal, settlement or claim using sufficient data and Gas. This is not a promise that all workflows remain convenient or available without the provided services. Delegating an encrypted reveal to the relay allows that relay to decrypt the preimage; it is not a time-locked encryption guarantee.

## Oracle and market risks

Book checks its uniform clearing price against a configured reference. The **±2% band** is `BookTypes.BAND_BPS = 200`; the TWAP window is **1,800 seconds** (`TWAP_WINDOW`). [BookOracle](../contracts/src/book/BookOracle.sol) rejects invalid or stale Chainlink rounds using the configured heartbeat; [BookListing](../contracts/src/book/BookListing.sol) caps a heartbeat at **one day** (`BookTypes.MAX_HEARTBEAT`). An unavailable reference can stop crossing settlement. A valid reference may still differ from a price available to a user elsewhere, and a thin or manipulated pool can weaken a TWAP's usefulness.

A nonempty Book epoch can be voided after its additional **600-second settlement window** (`BookTypes.SETTLE_GRACE`, `SealedBook.voidExpired`). Launch has an **unfinalized-sale abort after 7 days** from reveal end (`LaunchConstants.SETTLE_GRACE`, `SealedSale.abort`). These are callable contract paths, not automatic refund timers. Matching reveal/claim data may still be necessary afterward.

Locked Launch liquidity does not lock the token price, prevent losses or create a redemption guarantee. A successful sale may create no position if its computed liquidity amounts round to zero; token-reserve caps and actual position usage also affect the liquidity amount. See [Launch](modules/launch.md).

## Payout and refund risks

- A promise of refund entitlement is not a promise of automatic execution, private delivery or the same net value after fees.
- Publicly funded Launch bids, Book orders and Give donations do not receive the same Vault refund treatment as adapter-funded positions.
- Vault refunds can incur a new vetting fee. Limited note slots, remainder amounts and defined deposit failures can produce public dust payouts.
- Empty-data deposit failures in Launch, Book and Give abort the claim/refund instead of forcing a dust fallback. Transfer failures can also revert execution. Native fallback behavior is module-specific: Launch can use WBNB; Give and Send do not offer the same fallback.
- Losing a commitment preimage, choosing a malformed reveal or losing the recipient's key can prevent a permitted claim path. A support operator cannot reconstruct those secrets from the public commitment.
- Book carry preserves an already-revealed order; it is neither re-sealing nor a guarantee of trading in the next epoch.
- A gift is bearer-secret control, not a named-recipient or one-person-one-claim entitlement. A displayed expiry does not revoke the secret on-chain.

Implementation references: [QuoteTransfers](../contracts/src/launch/sale/QuoteTransfers.sol), [VaultNotes](../contracts/src/book/VaultNotes.sol), [GiveEscrow](../contracts/src/give/GiveEscrow.sol), [GiftAdapter](../contracts/src/send/GiftAdapter.sol).

## Client, chain and transaction outcome

Recovery material, note secrets, recipient keys and commitment preimages must be retained independently of a running browser session. Encryption does not make a compromised device trustworthy. A malicious or substituted client can alter instructions before a proof is generated; context binding protects the resulting encoded instructions, not the user's intentions before that point.

Confirm the network, current deployment addresses, token and recipient. Public-chain transactions may be irreversible. A relay response, wallet notification or transaction hash is not enough to establish successful settlement. Check the receipt and the relevant contract state before retrying an operation whose outcome is unknown. A failed transaction may still incur Gas costs, and chain reorganizations can change recently observed results.

See [privacy](privacy.md) for information disclosure, and the [module pages](modules/vault.md) for the exact conditions of each funding and exit path.
