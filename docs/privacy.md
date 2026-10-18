# Privacy: what the protocol conceals and what remains visible

HushCross combines a note-based Vault, optional one-time receiving addresses and sealed-order mechanisms. These protect different information at different stages. They do not make all transactions, counterparties or network activity private.

This is a source-available contract release. The public website currently runs in demonstration mode. The following describes protocol boundaries, not proof that every displayed client feature is operating against deployed contracts.

## Vault proofs and the approved set

A deposit places an amount, label and precommitment into a pool commitment tree. Deposits are public. A withdrawal uses a zero-knowledge proof to demonstrate knowledge of a spendable note, membership in the pool state and inclusion in the association set, without identifying the original deposit selected by that proof. A public nullifier prevents the same note state from being spent again.

[PrivacyPool.validWithdrawal](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/PrivacyPool.sol) requires a known state root and **the latest** association root from Entrypoint. It also binds the processing contract and encoded instructions through the withdrawal context. [Entrypoint.updateRoot](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/Entrypoint.sol) is restricted to the authorized postman role.

Screen builds the approved set from public deposit activity and its screening policy. The root is an approval-set commitment, not identity verification or a guarantee about the origin of every asset. A new label must be included in a published root before a normal withdrawal can use it. Root updates may invalidate an already-generated proof, and removing a label from the latest set can prevent its ordinary withdrawal.

The contract verifier does not require the official website. Independent proof construction is possible when the necessary note secrets, state data and current association-set data are available. It cannot compensate for a label that is absent from the required root.

## Visibility by mechanism

| Mechanism | Information concealed by the mechanism | Information still exposed |
|---|---|---|
| Vault withdrawal | Which original deposit the valid proof spends | Withdrawal amount, processor, nullifier, new commitment, transaction and timing; processor payout details |
| Send to a one-time address | The recipient's long-term receiving identity is not stated by the announcement itself | One-time address, asset, amount, relay/caller, fees, stipend, announcement and later address activity |
| Gift | Spending secrets are not placed in the GiftAdapter call as plaintext secrets | Withdrawal/re-deposit in the same transaction, share values and new precommitments, timing, dust payouts; anyone with the link may possess the secrets |
| Launch commit | Price, maximum spend and recipient committed with the salt are not revealed by the hash alone | Sale, commitment, escrow, funding path and time; public-wallet payer when publicly funded |
| Book commit | Limit price, target quantity, recipient and salt committed in the preimage | **Market, epoch, side, escrow asset and amount**, commitment, funding route and time |
| Give | Vault proof does not identify the original deposit spent into a contribution | Campaign, beneficiary, amount, counts, receipt hashes and time; a public donation's payer |

Sources: [HushSendAdapter](../contracts/src/send/HushSendAdapter.sol), [GiftAdapter](../contracts/src/send/GiftAdapter.sol), [SealedSale](../contracts/src/launch/SealedSale.sol), [SealedBook](../contracts/src/book/SealedBook.sol), [GiveEscrow](../contracts/src/give/GiveEscrow.sol). Calldata and storage are public even when a particular event omits a field. Escrow amounts may also allow inferences about the hidden order quantity or budget.

Launch and Book preimages become public at reveal. Book's band-fail carry moves the **same, already-revealed order** to the next epoch; it does not hide its contents again. See [Book](modules/book.md#voids-and-carry).

## Standard amounts, timing and address reuse

The product's standard net amounts are **0.02 / 0.1 / 0.5 / 2 / 10 BNB** and **20 / 100 / 500 / 2,000 / 10,000 USDT**. The values appear in [BookTypes.bnbUnits/usdtUnits](../contracts/src/book/BookTypes.sol) and [DeployAll's unit helpers](../contracts/script/DeployAll.s.sol), and are used by module refund routines. They are not a base-pool rule requiring every withdrawal to use a denomination.

Common amounts and waiting can reduce distinctive patterns, but cannot ensure a particular anonymity level. The useful comparison set depends on actual activity, amounts, timing, screening membership and observer knowledge. A client privacy score or suggested wait is advisory, not a proof that links cannot be inferred.

Address reuse, exact-value round trips, repeated destinations, public funding of recipient Gas, consolidating one-time addresses and revealing receipts or gift links can undo intended separation. A public payout fallback makes that payout visible even if the preceding funding originated in the Vault.

## Hush ID and one-time addresses

A stealth meta-address contains public receiving keys. The sender derives a one-time address and publishes an announcement so the receiver can discover it using their private receiving material. Send's announcement uses ERC-5564 **scheme 1**, defined by `HushSendAdapter.SCHEME_ID`; key registration is represented by the [ERC-6538 interface](../contracts/src/standards/IERC6538Registry.sol).

Neither standard hides the one-time address's balance or subsequent transactions. Registering a meta-address from an identifiable account can associate that account with the registration. A human-readable directory or a link resolver also introduces its own availability and integrity assumptions.

Gas stipends can avoid an immediate transfer from a familiar public address, but the stipend itself is visible and depends on the funding service. Send forwards supplied `msg.value`; it does not promise a fixed stipend or later replenishment. Other post-claim top-ups, when offered by a relay, are service behavior rather than a right enforced by the module contracts.

## Services and network privacy

The RPC/proxy, Screen, relay, indexer and metadata host can see requests sent to them and ordinary network metadata such as IP addresses and request times. An indexer query can reveal interest in an address or transaction even if its response contains only public chain data. Generating a proof locally does not anonymize these requests.

A relay receives the public proof, transaction instructions and payout information needed for execution. It should not receive the note's private witness, recovery phrase or wallet password for an ordinary withdrawal. A delegated reveal is different: encrypting a reveal preimage **to the relay** lets that relay decrypt it. Scheduling publication for the reveal window is not a cryptographic guarantee that the relay cannot learn it earlier. Preserve your own reveal material and do not rely on a delegated service as the only recovery path.

Gift fragments, receipt secrets and local backups can leak through a compromised client, browser extension, clipboard, synchronization tool or shared screen. Browser-local encryption protects stored data only within its assumptions; it does not protect an unlocked session on a compromised device.

## Public fallback is not an exit for an existing replacement note

Launch and Book offer recipient-controlled ways to choose direct payment before re-depositing. Some refund routines also turn defined deposit failures into public dust. These paths operate while funds are still held by the module.

After a module successfully deposits a replacement note, the pool records that module as the original depositor. The modules have no ragequit forwarding entry point. The note holder then depends on the latest approved root for normal withdrawal. See [trust and risks](trust-and-risks.md#contract-created-notes-have-no-ragequit-route).
