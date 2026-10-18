# Gift

A gift shares control of a Vault note through secret-bearing material, such as a recipient link. GiftAdapter can turn a sender's withdrawal into gift notes, or turn a gift note into notes controlled by a recipient's own Vault keys.

The public website currently runs in demonstration mode. Link formatting, encrypted messages, QR codes, random share assignment and recovery reminders are client features; they are not implemented as ownership restrictions in the Gift contract.

## Funding and claiming

[GiftAdapter.gift](../../contracts/src/send/GiftAdapter.sol) processes a withdrawal and deposits back into the same registered asset pool. Its `GiftData` contains a list of new precommitments, gross deposit values, the relay fee and a dust recipient.

The contract requires **1–16 shares** (`MAX_SHARES = 16`), matching list lengths, distinct precommitments and gross values meeting the pool's current minimum. It checks the proof's processing contract, the registered pool and the current relay-fee cap.

```text
withdrawnValue = relayFee + sum(gross share deposits) + dust
relayFee = floor(withdrawnValue × relayFeeBPS / 10000)
```

The denominator, share cap and split are defined in `GiftAdapter.MAX_SHARES`, `BPS_DENOMINATOR` and `_split`.

- **Vault-funded gift:** the sender's note is withdrawn and replacement gift deposits are made atomically. Each successful deposit pays the current Vault vetting fee.
- **Publicly funded gift:** a wallet can deposit directly to the Vault with the gift precommitment. This is a normal public deposit, with that wallet recorded as depositor.
- **Claim to an address:** the holder uses the gift note to construct an ordinary withdrawal, for example through [Send](send.md).
- **Claim into a personal Vault:** the holder uses GiftAdapter again with new personal precommitments. This is another set of deposits, not a cost-free change of ownership of the old note.

A gift note must meet the same latest association-root and proof requirements as any other note. A newly created replacement label is not immediately withdrawable merely because its parent withdrawal succeeded.

## Bearer-secret and expiry limits

GiftAdapter has no expiry timestamp, named claimant, per-person counter or sender-exclusive reclaim function. A client may display a deadline or offer a reclaim action, but that deadline is **not an on-chain timelock or automatic invalidation of the secret**.

Anyone with a share's usable spending secrets can attempt to spend it, including a sender who retained them. The pool prevents a successful double-spend through its nullifier check; it does not choose who is socially entitled to the gift. A common group link cannot enforce one share per person, and a recipient who has all share secrets may attempt to claim multiple shares.

Links that place secrets after `#` keep that fragment out of a normal HTTP request, but scripts running in the page, browser history, screenshots, clipboard tools and anyone receiving the link can still expose it. Do not treat possession of a URL as a verified identity.

## Fees, failures and exits

The relay fee is bounded by the current pool configuration. Each replacement deposit also incurs the current vetting fee; the **30-basis-point default** comes from [DeployAll.run](../../contracts/script/DeployAll.s.sol), not an immutable Gift fee. Dust is paid openly to `dustRecipient`.

GiftAdapter does not catch individual deposit failures. A failed share deposit, duplicate/used precommitment, fee check or payout reverts the whole transaction, including the withdrawal. A mined revert can still consume Gas.

Once GiftAdapter successfully deposits a share, it is that share's recorded original depositor. The adapter has no ragequit entry point. The holder therefore needs the label in the latest approved set to withdraw; neither a displayed expiry nor knowing the secret creates another on-chain exit. For a direct public deposit, the original public depositor retains the pool's depositor-only ragequit right; handing over the secret does not transfer that caller identity.

Sources: [GiftAdapter](../../contracts/src/send/GiftAdapter.sol), [PrivacyPool.ragequit](../../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/PrivacyPool.sol). See [trust and risks](../trust-and-risks.md).
