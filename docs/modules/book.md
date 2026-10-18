# Book

Book is a periodic sealed double auction for a listed base token against USDT. Orders commit privately to limit price and target quantity, reveal those fields, then settle at a common price that maximizes executable volume. The market, epoch, side, escrow asset and escrow amount are already public at commitment; the escrow amount may also help an observer infer the target quantity or budget.

The public website currently runs in demonstration mode. Example orders, markets and buttons are not evidence of live order submission.

## Market and timing rules

| Rule | Value | Contract source |
|---|---|---|
| Epoch | 600 seconds | `BookTypes.EPOCH_SECONDS` |
| Commit / reveal | First 480 seconds / remaining 120 seconds | `COMMIT_SECONDS`; `phaseAt` |
| Settlement window | Following 600 seconds; then anyone may void an unsettled nonempty epoch | `SETTLE_GRACE`; `SealedBook.voidExpired` |
| Orders | At most 500 per market and epoch | `MAX_ORDERS` |
| Band-fail carry list | At most 64 valid flagged orders per market and epoch | `MAX_CARRY` |
| Trading fee | 5 basis points, or 0.05%, per side | `FEE_BPS` |
| Reference band | Inclusive ±200 basis points, or ±2% | `BAND_BPS`; `BookMath.withinBand` |
| TWAP window | 1,800 seconds | `TWAP_WINDOW` |
| Default minimum buy escrow | 5 USDT | `DEFAULT_MIN_QUOTE` |
| Refund precommitments | At most 16 on a normal reveal | `MAX_REFUND_NOTES`; `SealedBook._checkShape` |

Sources: [BookTypes](../../contracts/src/book/BookTypes.sol), [BookMath](../../contracts/src/book/BookMath.sol), [SealedBook](../../contracts/src/book/SealedBook.sol).

The owner lists markets and can change their minimum escrows. The default sell minimum is the reference-price equivalent of the default quote minimum, rounded up to the market lot. If the reference cannot be read at listing, it falls back to one lot; it is not always a guaranteed fixed USDT value. See [BookListing.defaultMinEscrowLinked](../../contracts/src/book/BookListing.sol).

Prices must be positive multiples of a market's tick; quantities must respect its lot. Prices, quantities and escrow fields use the `MAX_UINT128` bound, and cumulative quantity at a price level must fit the stored prefix.

## Funding and reveal

A buy escrows USDT. A sell escrows the base token. Public funding uses `SealedBook.commit`; [BookAdapter.fundOrder](../../contracts/src/book/BookAdapter.sol) binds the order commitment to a Vault withdrawal and deducts its relay fee before escrow.

With the BNB and USDT Vault pools, buys can use private USDT funding, and WBNB sells can use private BNB funding that the adapter wraps. Selling another base asset from a Vault would require that asset's registered pool; the existence of a BTCB, ETH or Launch-token market does not itself create such a pool.

The commitment binds the chain, Book contract, market, epoch, side, limit, quantity, recipient, refund-precommitment hash, flags and salt. Reveal opens that data. Buy escrow must cover the rounded-up limit-price cost plus its fee; sell escrow must cover quantity (`BookMath.buyEscrowRequired`, `validity`). Economically invalid revealed orders do not trade. A matching public, unrevealed copy in the current epoch may be displaced by an adapter-funded commitment, with the public payer refunded in the same transaction.

## Clearing is checked on-chain

Anyone may submit `pLow`, `pHigh`, `pivot` and the marginal level during the settlement window. These are a clearing certificate checked against revealed orders, not a separate zero-knowledge clearing proof.

[BookClearing](../../contracts/src/book/BookClearing.sol) verifies the tight maximum-volume price interval, a pivot proving no greater volume exists outside it, and the correct marginal allocation level. The chosen price is the interval midpoint on the tick grid, with half-ticks rounded up (`BookMath.midpoint`). Better-priced eligible orders have priority; cumulative pro-rata rounding handles the marginal level.

The reference price is read inside `settle`. [BookOracle](../../contracts/src/book/BookOracle.sol) uses the ratio of base/USD and USDT/USD Chainlink feeds, or the configured V3 TWAP. Nonpositive, future-dated, incomplete or stale Chainlink rounds fail; the market's configured heartbeat is enforced, with a maximum of **one day** (`BookTypes.MAX_HEARTBEAT`, `BookListing.chainlinkLinked`). A missing or unavailable TWAP also prevents crossing settlement.

## Voids and carry

- No crossing orders: anyone may use `settleNoCross`; nothing trades.
- Accepted clearing certificate outside the reference band: the epoch is voided as a band failure; the price is not moved to the band edge.
- No settlement before expiry: anyone may call `voidExpired`; elapsed time alone does not execute the transaction.
- A successful cleared epoch does not automatically roll its partial fills into a new sealed order.

**Carry is public, not re-sealing.** Only a timely band-fail settlement attempts to carry flagged valid orders. The bounded list is moved into the next epoch as already-revealed orders with the **same commitment**, not a new secret preimage. Orders outside the carry list, a full next epoch, incompatible next-epoch state or prefix overflow remain refundable in the voided epoch. Carried orders can be carried again after a subsequent qualifying band failure; a flag does not promise immediate execution or a fixed refund time. See `SealedBook._listCarry`, `_carry` and `_carryOne`.

## Claim, fees and exits

A caller must submit a claim after the order's current epoch is finalized. Unrevealed orders use `claimUnrevealed` with their matching preimage; a lost preimage can prevent this path.

- Bought base tokens, including WBNB, and a seller's USDT proceeds always go to the committed recipient. Counterparty proceeds do not automatically enter the Vault.
- Public orders also receive their unspent escrow directly.
- For Vault-funded orders, normal `claim` can re-deposit only their own unspent escrow: USDT buy refunds and BNB from an unwrapped WBNB sell refund. Remaining dust is paid publicly; WBNB-side dust is paid as WBNB.
- `claimToRecipient` skips re-depositing. For Vault-funded orders only the recipient may choose this path; for public orders it is permissionless but still pays the fixed recipient.

Buyer cost is rounded up; seller gross proceeds are rounded down. Each side pays its configured constant trading fee. The rounding surplus and both fees go to treasury (`BookMath.payment`, `SealedBook._storeCleared`). Relay fees, transaction Gas and current vetting fees on replacement notes are separate.

[VaultNotes](../../contracts/src/book/VaultNotes.sol) converts reason-bearing deposit failures to public dust, but an empty-data failure reverts with `VaultDepositStarved`. Failed transfers or invalid clearing proposals revert rather than fabricate a settlement. Once a replacement note has successfully entered the Vault, the Book has no ragequit forwarding entry point; see [trust and risks](../trust-and-risks.md).
