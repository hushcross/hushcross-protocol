# Book (dark pool)

Sealed limit orders in 10-minute batches (8 minutes commit, 2 minutes reveal). Every fill in a batch uses one clearing
price, which must be within 2% of the oracle reference (Chainlink). Orders are sealed on-chain until reveal; a delegated relay can access their reveal data earlier. Public funding
and timing can still create links.

| Command | Purpose |
|---|---|
| `hcx book pairs` | Markets (`WBNB/USDT`, `BTCB/USDT`, `ETH/USDT`, …), reference price, `priceStep`, `sizeStep`, `sellFromVault` |
| `hcx book epoch --pair <id>` | Current batch phase and deadlines, settling batch, recent clearings |
| `hcx book order --pair <id> --side buy\|sell --price <p> --amount <q> [--rollover] [--from vault\|wallet]` | Place a sealed order |
| `hcx book orders [--pair <id>]` | Your orders with status, fills and claimable payout |
| `hcx book claim --order <id>` | Claim fills and refunds after the batch is final |
| `hcx book rollover --order <id>` | After `book claim`: place the unfilled rest again in the current batch |
| `hcx book revealed --pair <id>` | Revealed orders of the last finished batch (public after reveal) |
| `hcx book settle --pair <id> --epoch <n>` | Anyone may submit a finished batch (wallet transaction) |

`--price` must be a multiple of `priceStep`, `--amount` of `sizeStep`. Buys escrow USDT (cost plus 0.05% fee); sells
escrow the base token. Vault funding (default) uses one note and the relay; only the WBNB market can sell from the BNB
vault. Payouts of vault-funded orders go to one-time addresses (`hcx incoming`, `hcx onetime move`).

Timing matters: an order placed late in the commit phase may land in the next batch. Show `epoch.commitEndsAt` from
the plan. Do not describe expected fills or prices as predictions.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
