# Vault: balance, deposit, exit, activity

## `hcx balance` / `hcx notes [--all]`

Read-only. `vault` is spendable now; `inReview` waits for the approved-deposit list; `agenticWallet` is the public
wallet (when `baw` is signed in). `units` lists the standard amounts. `hcx notes` lists notes with `mixedWith`
(how many approved deposits in the same pool it blends with).

## `hcx deposit --asset BNB|USDT --amount <n>`

Moves funds from the Agentic Wallet into the vault. The amount must be a sum of standard units; each unit becomes one
note.

Plan (no `--confirm`):

```json
{
  "step": "plan",
  "summary": {
    "action": "deposit", "asset": "BNB", "vaultReceives": "0.12", "walletPays": "0.120361083249749247", "reviewFeeBps": 30,
    "notes": [ { "unit": "0.1", "count": 1, "walletPaysEach": "0.100300902708124373", "reviewFeeEach": "0.000300902708124373" },
               { "unit": "0.02", "count": 1, "walletPaysEach": "0.020060180541624874", "reviewFeeEach": "0.000060180541624874" } ],
    "transactions": 2,
    "privacy": "The deposit itself is public and linked to the Agentic Wallet. ..."
  },
  "firstEffect": { "kind": "wallet_transaction", "to": "0x202B…058A", "valueBnb": "0.100300902708124373", "requireAppConfirmation": false, "risks": [], "addressRisks": [], "simulation": { ... } },
  "next": "hcx deposit --asset BNB --amount 0.12 --confirm"
}
```

Show: what the vault receives, what the wallet pays, the review fee, number of transactions, the Binance preview
(`to` must be the entrypoint from `hcx contracts`; for USDT the first transaction is the USDT approval) and risks.

With `--confirm`, each transaction receives a fresh Binance preview. Before every execute the user must review
parsedTx, risks and authorityChanges and personally type that preview's requestId in a terminal; an earlier confirmation
does not cover the next transaction. Headless execution is refused and the agent must not create a PTY or supply the ID. If Binance asks for approval in the App,
hcx prints a notice and waits up to about 5 minutes; tell the user to open Binance App > Wallet > Agentic Wallet and
approve. Result:

```json
{ "step": "done", "result": { "deposits": [ { "txHash": "0x…", "walletPaid": "0.100300902708124373", "notes": [ ... ] } ], "next": "Notes are in review. ..." } }
```

Then check `hcx balance` until `vault` shows the amount (review time depends on service and chain conditions; approval is not guaranteed).

If the result is unknown, do not re-run this deposit command: note indices are reserved before the uncertain-send
boundary, and a new run can create another payment. Inspect `hcx wallet pending`, reconcile a user-checked transaction
hash and rescan/read owned notes. `wallet reconcile --confirm` only records verified evidence; it does not replay this
command. For an interrupted auto job, `auto recover --id <job>` can restore only a fully covered pre-submission funding
stage to screening. See [wallet.md](wallet.md); an incomplete or unresolved outcome must remain blocked.

## `hcx exit --note <id>`

Public exit: returns a note to the wallet that deposited it, publicly linked. Only for notes that cannot pass review
(`declined`). Needs the same Agentic Wallet that made the deposit.

## `hcx pools`, `hcx vault rescan`, `hcx vault backup --out <file>`

`pools`: approved and total deposits per pool (the crowd a note hides in) and fee settings. `vault rescan`: walks both
pools again for this vault's notes (after importing an old phrase). `vault backup`: writes an encrypted backup file
(mode 600, never overwrites) protected with `HCX_BACKUP_PASSWORD` or the vault password; restore only with a compatible client; verify version and real-chain mode first.

## `hcx activity [--limit n]`

Local history plus relay jobs (`delayed`, `submitted`, `confirmed`, `failed`) with transaction hashes.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
