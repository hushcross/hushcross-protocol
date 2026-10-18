# Send

Send connects a Vault withdrawal to a recipient. The recipient may be an ordinary public address or a one-time address derived from a stealth meta-address, used by the Hush ID receiving flow.

The public website currently runs in demonstration mode. This page describes the contract mechanism, not a claim that every displayed receiving or sending workflow is enabled on the public website.

## Contract flow

[HushSendAdapter.send](../../contracts/src/send/HushSendAdapter.sol) takes a registered pool, a withdrawal and its proof. The encoded `SendData` contains the recipient, relay-fee recipient, relay fee in basis points, optional ephemeral public key and optional announcement metadata.

1. The adapter checks that it is the proof's processing contract and that the pool is registered for its asset.
2. It checks the relay fee against the asset's current Entrypoint cap.
3. It calls the pool's withdrawal function and verifies the received balance delta.
4. If announcement fields are supplied, it calls the ERC-5564 Announcer with **scheme 1** (`HushSendAdapter.SCHEME_ID`). Both fields must be nonempty; the metadata's first byte is used as a view tag by the receiving scheme.
5. It pays the relay fee and forwards the remainder to the recipient. Any BNB supplied as `msg.value` is also forwarded to that recipient as a Gas stipend.

With both announcement fields empty, the same adapter sends to an ordinary address without an announcement. The proof context binds `SendData`; the relay cannot replace those encoded payout instructions while retaining the proof.

Hush ID registration concerns the receiving keys. The [ERC-6538 registry interface](../../contracts/src/standards/IERC6538Registry.sol) exposes stealth meta-address registration and lookup; a human-readable alias or a receiving link is a client/directory feature, not a naming guarantee made by the Send adapter. The included [registry reference implementation](../../contracts/src/standards/ERC6538Registry.sol) is for local-chain use.

## Fees and recipient Gas

```text
relayFee = floor(withdrawnValue × relayFeeBPS / 10000)
recipient asset amount = withdrawnValue - relayFee
```

The denominator is `HushSendAdapter.BPS_DENOMINATOR`. The configured cap is read on each call; the deployment default is **150 basis points (1.50%)**, from [DeployAll.run](../../contracts/script/DeployAll.s.sol). There is no separate Send protocol charge in the adapter.

A stipend is additional BNB funded by the transaction caller. The contract does **not** fix its amount, promise its availability or automatically replenish the recipient later. For a token transfer, the token payout and BNB stipend are separate asset movements. A subsequent re-deposit by the recipient requires Gas and incurs the current Vault deposit fee.

## What is visible

`HushSent` exposes the pool, recipient, caller, asset, withdrawn amount, fee, stipend and whether an announcement was made. Announcements and one-time-address balances are public. A one-time address avoids reusing a receiving address; it does not hide its existence, amount, later spending or network requests.

Registering keys from a familiar account, funding a one-time address from that same account, consolidating receipts, or returning funds to a known address can create links. See [privacy](../privacy.md).

## Failure and recovery boundaries

Invalid proofs, unregistered pools, an excessive fee, malformed announcement presence, a failed payout or an unexpected balance delta revert the whole call. Send does not leave a queued payout in the adapter. A mined failure can still cost Gas; check the transaction outcome before retrying.

The adapter checks balance changes rather than requiring an empty starting balance. Unsolicited transfers left in the adapter are not a user deposit or a recoverable Send balance; there is no generic sweep function. Send funds through the specified entry points, not by transferring assets directly to the adapter address.

A missing relay is an availability problem, not an alternate authorization mechanism. Independent submission still needs the valid proof, appropriate caller execution and transaction Gas. Contract-created Vault notes retain the [Vault exit limitation](vault.md#exit-paths-and-failures).
