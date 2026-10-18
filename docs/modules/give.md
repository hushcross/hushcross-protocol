# Give

Give supports immediate tips and deadline-based goal campaigns in BNB or configured USDT. Campaign details live in [GiveRegistry](../../contracts/src/give/GiveRegistry.sol); assets and payment events live in [GiveEscrow](../../contracts/src/give/GiveEscrow.sol).

The public website currently runs in demonstration mode. This page explains the contract rules rather than promising that displayed campaigns or contribution controls are live.

## Campaign types

| Type | Rule |
|---|---|
| Tip | `goal = 0` and `deadline = 0`. Each donation is forwarded immediately to the fixed beneficiary. |
| Goal | A positive goal and a duration from 1 hour to 90 days. Contributions are accepted strictly before the deadline. At or after it, `settle` records whether total contributions reached or exceeded the goal. |

The duration bounds are `GiveTypes.MIN_DURATION` and `MAX_DURATION`; the goal and each donation are bounded by `MAX_AMOUNT = type(uint128).max`. Campaign titles are capped at **240 bytes**, metadata URIs at **256 bytes** (`MAX_TITLE_BYTES`, `MAX_URI_BYTES`). These are byte limits, not character counts. Sources: [GiveTypes](../../contracts/src/give/GiveTypes.sol), `GiveRegistry.create`.

The beneficiary, asset, goal, deadline, title and metadata pointer are public. The registry does not provide a later campaign-edit or beneficiary-substitution function. Off-chain metadata remains a separate availability and content-trust concern.

## Contribution flow

- A public wallet calls `GiveEscrow.donate`, providing a refund address for a Goal donation. This transaction exposes that public funding wallet.
- [GiveAdapter.fund](../../contracts/src/give/GiveAdapter.sol) instead withdraws from a registered Vault pool, validates that its asset matches the campaign, deducts the relay fee and calls `donateFromAdapter`.
- A Vault-funded Goal donation includes fresh refund precommitments and a dust payout address. The escrow reserves **1–16** precommitments (`GiveEscrow.MAX_NOTES`, `_reserve`) and rejects duplicates, already-reserved entries and precommitments already used in the Vault.
- A Tip sends its contribution to the beneficiary in the same transaction; it does not create a refundable Goal balance.

An optional receipt is a hash of a user-held secret. `receiptTotal` exposes the accumulated amount for a hash; `verifyReceipt` computes the same lookup from a supplied secret. Publishing the secret or sending it to a remote RPC for a read call discloses it to that recipient. A receipt is not a guarantee of donor identity or anonymity.

## Settlement and refund

There are no automatic deadline payments:

1. After a Goal's deadline, anyone may call `settle`.
2. If `total >= goal`, anyone may call `release`; funds go only to the campaign's fixed beneficiary. Release is not an arbitrary caller payout.
3. If the goal was not reached, anyone may call `refund` for each donation index. The recorded funding route and payout data determine where the funds go.

A **public donation** refunds its entire contribution amount directly to its registered refund address. A **Vault-funded donation** attempts a largest-unit-first split into replacement notes using the current vetting fee and minimum deposit. Remaining dust goes to the recorded payout address. Sources: `GiveEscrow.settle`, `release`, `refund`, `_refundVault`; [GiveMath](../../contracts/src/give/GiveMath.sol).

The contract checks `total >= goal` only at settlement after the deadline; reaching the goal early does not unlock early release. There is no general donor cancellation or beneficiary-controlled early refund function.

## Charges and failure behavior

GiveEscrow does not deduct a separate Give protocol fee. For adapter funding, `donated = withdrawnValue - relayFee`; the relay fee must not exceed the asset's current Entrypoint cap (`GiveAdapter._check`). Transaction Gas and Vault deposit fees are separate. A replacement refund note pays the current vetting fee again, so a full contribution refund is not a promise of the same net value remaining inside the Vault.

Refund fallback matters:

- If no usable pool configuration exists, `_refundVault` pays the whole refund to the recorded payout address instead.
- A replacement deposit reverting with reason data becomes public dust.
- An empty-data deposit revert aborts the refund with `DepositStarved`; it does not silently expose the funds through a forced fallback.
- Failed native/token payouts revert. Unlike the Launch quote-transfer path, Give has no automatic WBNB fallback for a recipient that rejects BNB.

A reverted transaction does not complete the release or refund, though it can cost Gas. Check the receipt before retrying. Successfully created replacement notes are deposited by GiveEscrow, which has no ragequit entry point; they require inclusion in the latest approved root for ordinary withdrawal. See [Vault exits](vault.md#exit-paths-and-failures).

## Privacy scope

Campaign identity, contribution amounts, counts, receipt hashes and times are visible. Vault funding hides the original note selected by the withdrawal proof; it does not hide the campaign destination or make a publicly funded donation private. Reusing receipt secrets, payout addresses or identifiable timing can connect contributions. See [privacy](../privacy.md).
