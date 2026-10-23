# Automation and confirmation boundaries

A recurring instruction or spending budget can guide read-only checks and planning. It does not authorize the agent
to bypass execution-time approval, Binance's preview/execute requirements, or stricter host-platform rules.

- Without `--confirm`, every auto execution command produces a scoped plan only. It does not advance real jobs.
- Before execution, show the selected job IDs, requested versus actual pre-fee amounts, untouched remainder, reserve,
  funding, recipients, fees and privacy findings; obtain the user's explicit approval of that current scope.
- `auto run --id <job>` selects only that job. Without `--id`, the scope is all unfinished jobs shown in that invocation's
  summary. Creating, retrying or going ahead with a job does not silently advance unrelated jobs.
- `--allow-wallet` is a separate permission to use wallet funding within that shown scope, not a standing approval of
  every transaction. It is ineffective as a substitute for `--confirm` or the per-preview human interaction.
- Each Binance wallet transaction requires a fresh preview and the user personally typing that preview's requestId in
  a terminal after reviewing parsedTx, risks and authorityChanges. Null authorityChanges is unknown/not reported.
  An agent must not create a PTY, type the ID, spoof isTTY, or simulate a human to get past this gate. A TTY is not
  cryptographic proof of a human. Headless wallet execution is refused.
- Developer Mode is enabled by the user in Binance App only. If it is off/expired, stop before preview. Turn it off
  when finished. Complete any required Binance App approval personally. This does not require enabling Developer Mode
  for local pending inspection, RPC-only reconciliation or local job recovery.
- Wallet reconciliation/discard confirmations must be entered by the user too. `user_attested_exact_tx` is not provider
  proof; `--not-sent` requires verified non-submission and a no-longer-pending App order, not just an unlocked App status.
- Never automatically add `--accept-risk`, use `auto go`, change recipients, exit publicly, or retry an unknown outcome.
  Inspect state and ask the user first. Confirmed job continuation is not an unattended daemon or a new schedule.

Report the actual job/transaction status after execution. A successful command submission is not an on-chain confirmation.

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
