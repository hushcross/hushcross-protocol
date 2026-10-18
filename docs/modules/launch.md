# Launch

Launch escrows sealed bids for a fixed-supply token sale, then checks a uniform clearing price on-chain. Vault and public-wallet funding are supported by different paths, with different refund treatment.

The public website currently runs in demonstration mode. The deployed contract mechanisms described here are distinct from example sales or actions shown by the website.

## Sale configuration

[LaunchFactory](../../contracts/src/launch/LaunchFactory.sol) creates a [HushToken](../../contracts/src/launch/HushToken.sol), a sale and, where needed, a creator vesting wallet. HushToken mints its supply only in its constructor and supports EIP-2612 permit; it has no owner-controlled mint, tax, blacklist or pause function.

| Setting | Contract rule | Source |
|---|---|---|
| Quote asset | BNB or configured USDT | `LaunchFactory.validateParams` |
| Commit window | 1–72 hours | `LaunchConstants.MIN_COMMIT_DURATION`, `MAX_COMMIT_DURATION` |
| Reveal window | 1 hour–7 days | `MIN_REVEAL_DURATION`, `MAX_REVEAL_DURATION` |
| Live bid capacity | Creator selects a positive cap, at most 1,000 | `MAX_BIDS_LIMIT`; `SealedSale.commit` |
| Liquidity target | 30–80% of the raise **after** the protocol fee, subject to token-reserve and rounding limits | `MIN_LIQUIDITY_BPS`, `MAX_LIQUIDITY_BPS`; `LaunchClearing.liquidity` |
| LP token reserve | At least 10% of total token supply | `LaunchFactory.validateParams` |
| Creator allocation | At most 10% of total supply | `LaunchFactory.validateParams` |
| Creator vesting | 90 days–4 × 365 days if an allocation exists; starts at reveal end | `MIN_VESTING_DURATION`, `MAX_VESTING_DURATION`; `LaunchFactory.createSale` |
| Refund precommitments | At most 16 | `MAX_REFUND_NOTES` |
| Unfinalized-sale escape | `abort` becomes available 7 days after reveal end | `SETTLE_GRACE`; `SealedSale.abort` |

Constants: [LaunchTypes](../../contracts/src/launch/LaunchTypes.sol). Supply equals sale allocation plus LP reserve plus creator allocation; supply and accepted price/amount fields are bounded by `MAX_AMOUNT = type(uint128).max`.

## Commit → reveal → finalize → claim

**Commit.** A commitment binds the chain, sale contract, sale identifier, price, maximum spend, recipient, refund precommitments and salt (`SealedSale.computeCommitment`). Escrow and timing are public; the committed price and recipient are not revealed by the hash alone. A public wallet uses `commit`. [LaunchAdapter.fundBid](../../contracts/src/launch/LaunchAdapter.sol) instead withdraws from a registered Vault pool, pays the relay fee and escrows the remainder.

The public minimum is the smallest configured unit. The adapter minimum is `floor(minEscrow × (10000 - currentMaxRelayFeeBPS) / 10000)`, read by `privateMinEscrow`. It is not an extra full-unit requirement after the relay fee. With the default unit/cap configuration, this is **0.0197 BNB or 19.7 USDT** rather than 0.02 BNB or 20 USDT. Sources: `SealedSale.privateMinEscrow`, [DeployAll](../../contracts/script/DeployAll.s.sol).

At capacity, a new bid must strictly exceed the smallest live escrow. The evicted bid can recover through late reveal after finalization. If a public, unrevealed copy has occupied a Vault bid's commitment, an adapter-funded bid can replace it and immediately refund that public payer; native escrow is returned as WBNB. This does not allow public bids to displace Vault-funded bids.

**Reveal.** Anyone with the matching preimage may reveal during the reveal window. Structurally malformed inputs revert. Economically invalid bids are recorded but excluded from clearing and retain a full-escrow refund entitlement. A valid bid demands `q = floor(maxSpend × 1e18 / bidPrice)` tokens. Preserve the exact preimage: a lost preimage, or one that cannot pass the structural reveal checks, can prevent recovery.

**Finalize.** Anyone proposes a price. [LaunchClearing.verify](../../contracts/src/launch/LaunchClearing.sol) checks that demand at or above it covers supply while demand strictly above it does not. If total demand is below supply, the accepted price is the floor. Better-priced bids fill first; the marginal tier is allocated proportionally using cumulative integer rounding. Each spend is rounded up to `ceil(fill × clearingPrice / 1e18)`.

A zero raise or a raise below `minRaise` makes the sale fail. If no finalization succeeds before the grace period, anyone may call `abort`; it is not an automatic timer. On failure, sale and LP-reserve tokens return to the creator and bids have full-escrow refund entitlements. The creator's separately allocated vesting wallet is not cancelled by this outcome.

**Claim.** Following finalization, anyone may call `claim` with the committed refund precommitments. Unrevealed or evicted bids use `lateReveal`, which settles them without participation in clearing. These are caller-triggered transactions, not automatic refunds. See [SealedSale](../../contracts/src/launch/SealedSale.sol).

## Fees, LP and creator proceeds

The sale fee is **1%** of the successful raise (`LaunchConstants.FEE_BPS = 100`, `BPS = 10000`). The liquidity target is calculated from the remaining raise and is capped by the LP token reserve. If either computed liquidity side rounds to zero, no position is created. Unused sale/reserve tokens in a successful sale are sent to the burn address; the creator separately calls `claimProceeds` for the recorded quote proceeds.

[LiquiditySeeder](../../contracts/src/launch/sale/LiquiditySeeder.sol) uses the accepted price as its pool initialization/alignment target, then mints a full-range PancakeSwap V3 position at `POOL_FEE = 2500`. Pre-existing pool state, alignment swaps and position rounding affect actual token usage. The position NFT stays in the sale: no function withdraws its liquidity or transfers the NFT. This does not lock the market price.

Trading fees remain collectible through `collectFees`: **half of each collected token goes to the creator and half to the sale's treasury; an odd base-unit remainder goes to treasury** (`SealedSale._splitFee`). This is separate from the initial sale fee and is not a return guarantee.

## Refund and failure paths

- Public-wallet bids pay their refund directly to the committed recipient; they do not enter the Vault.
- For Vault-funded bids, `claim` attempts a largest-unit-first split into replacement notes using the current deposit fee. Limited precommitments and remaining dust produce public payouts to the recipient.
- A deposit reverting with reason data falls back to dust. An empty-data revert fails the whole claim with `VaultDepositStarved`, rather than allowing insufficient execution Gas to force a public payout.
- The recipient can call `claimToPayout` for a revealed bid to receive tokens and the refund directly, before replacement notes have been deposited. This is not a ragequit for notes already in the Vault.
- Native quote payouts fall back to WBNB if the recipient rejects BNB. Other failed token transfers or liquidity operations can revert the relevant transaction.

Sources: `SealedSale.claim`, `claimToPayout`, `lateReveal`, `_settleBid`; [QuoteTransfers](../../contracts/src/launch/sale/QuoteTransfers.sol). Full-escrow refund entitlement does not mean fee-free recovery: a successful replacement deposit pays the current Vault vetting fee. Successfully re-deposited notes have the [contract-created-note exit limitation](vault.md#exit-paths-and-failures).

## Sale profile

Only the sale creator may call `LaunchFactory.setProfile` to set or clear a content hash and URI. The contract's URI cap is **200 bytes** (`MAX_PROFILE_URI`). Logo, description and social links remain off-chain. A reader must verify the fetched profile bytes against the on-chain hash and any logo against its profile hash. The pointer may be updated or cleared by the creator; content addressing does not make the pointer immutable or endorse the content.
