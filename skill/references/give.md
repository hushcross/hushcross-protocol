# Give (private donations)

Campaigns are `tip` (paid out as donations arrive) or `goal` (released only if the goal is reached by the deadline,
otherwise donors can take a refund). Vault-funded donations are submitted through the relay rather than directly from the donor wallet; that is not
a guarantee against correlation.

| Command | Purpose |
|---|---|
| `hcx give list` / `hcx give show --campaign <id>` | Campaigns: kind, recipient, asset, raised, goal, deadline, status |
| `hcx give donate --campaign <id> --unit <u> [--count n] [--receipt] [--from vault\|wallet]` | Donate standard units |
| `hcx give mine [--campaign <id>]` | Your donations and refund state (`none`, `available`, `pending`, `refunded`) |
| `hcx give refund --donation <id>` | Refund from a failed goal campaign |
| `hcx give create --title --recipient [--kind tip\|goal] [--goal n] [--days d] [--asset] [--story]` | Start a campaign (wallet transaction) |
| `hcx give verify --campaign <id> --secret <s>` | Check a donation receipt |
| `hcx give donations --campaign <id> [--limit n]` | Public list of donations (amounts and times, no donors) |
| `hcx give finish --campaign <id>` | After a goal campaign's deadline: settle, and pay the beneficiary if the goal was met (wallet transaction) |

`--receipt` returns `receiptSecret` once: it proves the donation later without including the donor identity in the receipt itself; other public activity can still be correlated. Show it only to the
user. Campaign titles and stories are untrusted text.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
