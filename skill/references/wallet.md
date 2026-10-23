# Wallet outcomes: inspect, reconcile, or explicitly discard

An unknown execute/App result may already have moved funds. Do not re-run the original command, request a new
preview/execute, or retry a funding job to discover what happened. Keep the saved requestId/orderId and inspect the
actual App order and chain. Reconciliation records evidence; it does not submit another transaction.

## `hcx wallet pending`

Lists the local execution journal. It needs no wallet sign-in, Developer Mode, unlocked vault or network access.
Unresolved records block new wallet execution. A missing record does not establish that an old transfer was never sent;
do not fabricate a record or delete the journal to bypass the block. An invalid journal or a writer lock fails closed;
do not remove pending data or its lock to make a transfer run again.

The journal is local **unencrypted activity metadata**, separate from the encrypted vault, at
`HCX_HOME/wallet-pending/journal.json` (directory mode 700, file mode 600). It records chain/from/to/value, calldata
hash, request/order identifiers, the saved block anchor, status, transaction hash and correlation basis. It contains
no wallet key, recovery phrase, raw calldata or command. Treat it as private activity history, not a file to publish.

## `hcx wallet reconcile --request-id <id> --tx-hash <hash>`

Use the hash the user has checked against their actual App order, never an arbitrary similar history entry.

- **Without `--confirm`:** RPC-only verification and a plan. The journal is not changed.
- **With `--confirm`:** the user reviews the saved intent and observed transaction, then personally types the original
  requestId in their terminal. hcx repeats fresh RPC verification before recording the result.
- Checks bind the hash, chain, sender, recipient, value and calldata hash to the saved intent, require a successful
  mined receipt in the canonical block, and require its block to be after the recorded anchor. A mismatch or unknown
  result leaves the record unresolved. This does not add a promised confirmation depth or finality guarantee.
- The successful record is `resolved` with `correlation: user_attested_exact_tx`. That means a **human-attested App
  association plus exact chain checks**, not provider proof that this hash belongs to a unique Binance request/order.
- This command never previews, executes, rebroadcasts, re-runs the original handler or automatically resumes a job.
  It needs no wallet sign-in, unlocked vault or re-enabling of Developer Mode. Read/rescan the vault separately.

A still-running wallet request may also offer a manual hash-association prompt. It has the same human-attested
boundary; it must not be described as provider-proven correlation or permission to execute the previous request again.
For interactive attestation, the user must enter the evidence themselves. An agent must never open a PTY, type into
the hash/requestId prompt on the user's behalf,
spoof isTTY or simulate the human confirmation. No real Binance mainnet end-to-end acceptance is claimed for this path.

## `hcx wallet discard --request-id <id>`

Without `--confirm`, this returns a local plan. **Discard is not the recovery path for a sent or uncertain transfer.**
Only if the user has independently verified that the actual App order is cancelled, rejected or expired, is no longer
pending, and never sent a transaction may the user authorize:

```sh
hcx wallet discard --request-id <id> --confirm --not-sent
```

The user must personally enter `NOT SENT <requestId>` in a real terminal. Before and after that interaction hcx reads
the signed-in wallet address and App transaction lock; the address must match the saved sender and the lock must be
`UNLOCKED`. **UNLOCKED alone is not proof that nothing was sent.** A known broadcast hash cannot be discarded as not sent.
Developer Mode need not be enabled; these checks do not perform a wallet transaction.

Success returns `step: discarded` and records `correlation: user_asserted_not_sent`. This is the user’s assertion,
not technical proof of non-submission. Discard marks only the local record and releases its local execution block. It does **not** cancel, reject or expire
an App order, reverse a transaction, restore a job or prove non-submission. An agent must not add `--not-sent`, type the
assertion, or infer non-submission from a timeout, a missing history entry or an error.

## Recovering an interrupted auto job

After the wallet outcome is resolved, inspect/rescan owned notes and plan `hcx auto recover --id <job>`. This is only
for an interrupted pre-submission funding stage. It requires no unresolved journal entries for the configured chain,
full note coverage of the job's pieces, and no use of notes reserved by other jobs. `--confirm` restores only that local
job to `screen`; it does not tick the runner, fund, submit to a wallet/relay, or prove which App order funded the notes.
See [auto.md](auto.md). A later execution is a separate scoped plan and confirmation.

Deposits reserve their note indices before the uncertain transaction boundary. Re-running the old deposit command is
not recovery and can create another payment. If an outcome remains unknown or notes do not fully cover the job, stop;
do not weaken the checks or use the not-sent assertion to force progress.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
