# Scoped jobs (`hcx auto ...`)

Jobs reserve vault notes, may require wallet deposits, wait for review/privacy conditions, submit through the relay,
and for bids/orders continue through their lifecycle. Job state is encrypted in the vault and survives process exits.
There is no unattended daemon: a later invocation must be explicitly confirmed to advance real jobs.

| Command (plan first) | Scope / purpose |
|---|---|
| `hcx auto send --to <recipient> --asset --amount [--delay m] [--gas-drop]` | Create one send job; amount is split downward into supported units |
| `hcx auto gift --asset --amount [--people n] [--message] [--expiry-hours h]` | Create one gift job; show packet total, unused remainder and fee reserve |
| `hcx auto donate --campaign <id> --amount <n>` | Create one donation job; amount is split downward |
| `hcx auto bid --sale <id> --price <p> --max-spend <s>` | Create one bid job; show escrow and funding note needed |
| `hcx auto order --pair <id> --side buy\|sell --price <p> --amount <q> [--rollover]` | Create one order job; show actual quote and funding |
| `hcx auto run [--id <job>] [--allow-wallet] [--wait s]` | Resume only the specified job, or the unfinished jobs shown in this plan when no ID is supplied |
| `hcx auto list [--all]` | Read job state and suggested next steps |
| `hcx auto recover --id <job>` | Plan recovery of an interrupted funding stage using existing owned notes only |
| `hcx auto retry --id <job>` / `auto go --id <job>` / `auto cancel --id <job>` | Only the named job; go overrides a weak privacy wait and requires explicit acceptance |

All state-changing commands above need `--confirm` to create, advance, recover, retry, go or cancel real jobs. Without it, plan mode
performs one scoped simulated tick and returns promptly; it does not wait for review or modify real job/vault state.
After the user approves the displayed scope, execution commands may drive it for the requested wait period (default 90 seconds).
`auto recover` is different: `--confirm` restores only local state and never ticks the runner.
`auto run --id <job> --confirm` never resumes other unfinished jobs. `--allow-wallet` additionally permits wallet funding,
but every actual Binance wallet transaction still requires the user's fresh preview/requestId confirmation in a real
terminal; neither this flag nor a standing mandate replaces it. See [autonomy.md](autonomy.md).

## Recover existing funding, without another payment

`hcx auto recover --id <job>` plans; `--confirm` makes only the local change. It is restricted to an `attention` /
`fund_interrupted` job still in its pre-submission funding stage. All work must remain unsubmitted. There must be no
unresolved wallet journal record for the configured chain, and existing owned notes must cover every piece without
taking another job's reservations. Failure leaves funding state unchanged; do not relax checks or request a new deposit.

Success moves only that job to `screen` with `recoveryBasis: existing_owned_notes` and `newWalletTransaction: false`.
It does not prove the notes came from a specific App order, automatically tick, submit to a wallet/relay, or resume the
original command. Read the resulting job and make a separate scoped plan before any later execution. See [wallet.md](wallet.md).

## Amounts are not arbitrary exact transfers

- **Send/donate:** the requested amount is split into supported units **downward**. For example, 35 USDT can produce
  an actual 20 USDT pre-fee action and leave 15 USDT untouched. Display `requestedAmount`, `amount`, `remainder` and
  `amountBasis`; the recipient's net receipt can be lower because fees are deducted. Do not say all 35 USDT was sent.
- **Gift:** the plan chooses supported packet units (at most 100 units); unused amount stays in the vault. The funding
  reservation includes a 2% margin rounded **up** to the smallest unit. `reservedAmount` is not the gift total or a claim
  that the entire reserve will be spent. Show requested amount, packet total, remainder, reserve and fees separately.
- **Bid/order:** funding may require the smallest supported note large enough for the quoted withdrawal/escrow plus fees.
  That funding note is not the same as the bid maximum, trade fill, amount paid to a recipient or ultimate spend.

`waiting` means a condition such as screening, privacy, a market window or relay status is not ready. Inspect the job and
plan a scoped resume later; do not execute a returned `next` string blindly. `attention` needs a user decision.
Gift links in finished jobs are bearer secrets. Unknown transaction outcomes must be reconciled before retrying.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.

## Interrupted wallet deposits

An unknown/pending deposit must not be retried automatically. Inspect `hcx wallet pending` and the actual App order,
then plan `wallet reconcile --request-id <id> --tx-hash <hash>` for a sent transaction. Its confirmed record is
human-attested exact-chain evidence, not provider order proof. Read/rescan notes and use `auto recover --id <job>`
only when its full existing-note and reservation checks pass; recovery does not tick or submit the job.
Only if the user verifies that the App order is no longer pending and no transaction was ever sent may they use the
explicit local discard procedure in [wallet.md](wallet.md), then authorize
`hcx auto retry --id <job> --deposit-not-sent --confirm` if appropriate. Neither not-sent assertion may be made by an
agent or inferred from a timeout, missing history or UNLOCKED status. Never re-run the original deposit as recovery.
