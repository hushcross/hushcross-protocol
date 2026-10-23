# Send, withdraw, pay, receive

## `hcx send --to <recipient> --asset BNB|USDT --amount <n> [--delay <minutes>] [--gas-drop true|false]`

Private payment out of the vault. Recipient: a `0x` address, a Hush ID name (`alice` or `@alice`), or a meta-address
(`st:bnb:0x…`). The amount must be a sum of standard units; each unit spends one approved note (change stays in the
vault). `--delay` (0-30, default 10) makes the relay wait a random time inside that window. `--gas-drop` attaches a
little BNB so a fresh USDT recipient can move funds (offered for larger USDT sends; never for BNB).

Plan summary fields: `recipient`, `amount`, `relayFee`, `relayFeeBps`, `recipientGets`, `gasDropBnb`, `notesUsed`,
`delayMinutes`, `privacyCheck` (`level`, `askUserFirst`, `findings[]` with `reason` and `tip`).
`firstEffect.kind` is `relay_request`: the request goes to the HushCross relay; the Agentic Wallet does not sign.

With `--confirm` the proof is made locally (a few seconds) and the relay job is returned:

```json
{ "step": "done", "result": { "job": { "jobId": "…", "status": "delayed", "amount": "0.1", "executeAfter": "…" }, "next": "…" } }
```

Follow with `hcx activity` for the transaction hash. For a Hush ID recipient the funds land on a one-time address the recipient can recognize and control using their keys. The address and transfers remain on-chain;
this does not guarantee that others cannot correlate them.

## `hcx withdraw --asset --amount [--delay] [--gas-drop]`

Same as `send` to the Agentic Wallet address. It links the vault to that wallet; the privacy check says so. Suggest a
fresh address or keeping funds in the vault when privacy matters.

## `hcx pay --to <recipient> --asset --amount`

Pays directly from the Agentic Wallet (no vault). To a Hush ID the payment goes to a fresh one-time address (receiver
private, sender visible). To a plain address it is a normal public transfer. Wallet transaction: verify the exact user-approved recipient/value (or decoded token transfer), show the actual
parsedTx, risks and authorityChanges, and require the user to type the fresh requestId in a terminal before execute.

## `hcx receive` / `hcx name claim --name <name>`

`receive` shows the Hush ID (`@name`), the meta-address and a pay link. `name claim` registers a short name for the
vault identity (relay pays; the Agentic Wallet is not involved). Result `{ "hushId": "@name" }` or `{ "reason": "taken" }`.

## `hcx request create --asset --unit <u> [--count n] [--note text]` / `hcx request list`

A pay link for this vault's Hush ID (needs a claimed short name). The payer opens it in the web app; the payment goes
to a one-time address this vault can recognize and control; it does not make the address invisible on-chain.

## `hcx incoming`, `hcx incoming move --id`, `hcx incoming send --id --to 0x…`, `hcx onetime move --id --symbol [--to 0x…]`

`incoming.payments` are payments found for this Hush ID (`unclaimed` / `in_vault` / `sent`). `incoming move` deposits one
into the vault from its one-time address; payments of the smallest unit are below the vault minimum after gas
(`below_minimum`), so forward those with `incoming send --to` (USDT needs a little BNB on the one-time address for gas). `oneTimeFunds` are one-time addresses that received sale tokens, Book trades or
refunds; `onetime move` moves BNB / USDT into the vault, or any holding to an address with `--to`.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
