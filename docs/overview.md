# HushCross overview

HushCross is a private-finance application on BNB Chain. A shared privacy vault supports payments, gift links, sealed-bid launches, batch trading and giving. It aims to reduce the public link between a funding deposit and a later use of those funds, not to hide every part of a transaction.

## Deployment and website status

As of **18 October 2026**, the current protocol contracts have been deployed on BSC mainnet, chain ID **56**. The [README](../README.md) provides the deployment table and explorer links. Read [contract verification](verify.md) before relying on a particular deployment.

The public [website](https://hushcross.fun) is currently a **demo with sample data**, marked by a demo banner. Its default interface is Pro mode in English. Demo balances, sales, orders and success screens are not evidence of a funded account, a live transaction or an available production service. Deployed contracts and a demonstration website are separate facts.

This repository provides **source-available contract code and documentation**. The website, client application and backend service implementations are not included. It is not a complete application distribution or a promise that the hosted services will remain available.

## Six features

### Vault

Deposit BNB or USDT into a shared Privacy Pools-based vault. The client tracks private notes and creates zero-knowledge withdrawal proofs locally. A proof demonstrates entitlement to spend an approved note without identifying its originating deposit in the withdrawal proof.

The client uses standard net amounts to reduce distinctive amount patterns. Approval by Screen and publication of an association-set root are separate from the deposit transaction itself. A confirmed deposit does not, by itself, mean it is ready for private spending. See [Vault](modules/vault.md).

### Send

Pay a regular address or a Hush ID. A Hush ID exposes public stealth-payment keys; the sender derives a one-time receiving address and emits an ERC-5564 announcement. The recipient uses their private keys to recognize and spend the payment. Ordinary-address payments do not need an announcement.

A relay can submit a proof-backed payment and supply a gas top-up when supported. The destination, amount, announcement and transaction timing are still public. See [Send](modules/send.md).

### Gift

Create bearer-secret links, including red packets split into several notes. The client places the gift secret and an encrypted optional message in the URL fragment. The fragment is not part of a normal HTTP request, but anyone who receives the full link can read it in their own browser and attempt to claim.

The same adapter supports funding gift notes and moving a claimed gift into a recipient's vault. Group links do not enforce one person per share. An application expiry is not a recipient-only lock in the adapter. See [Gift](modules/gift.md).

### Launch

Create a sealed-bid token sale. Bidders commit funds, reveal their bid terms and receive an allocation at a contract-verified uniform clearing price. A sale that does not meet its minimum raise fails. A successful sale can allocate liquidity to PancakeSwap V3, subject to token-reserve and rounding limits (a zero-sided allocation creates no position), with the LP position retained by the sale contract.

Vault-funded bids and public-wallet bids have different refund routes. Tokens go to the committed recipient; eligible unused vault-funded escrow can become new vault notes, with any remainder paid out separately. See [Launch](modules/launch.md).

### Book

Trade in periodic sealed double auctions rather than a continuously visible order book. Revealed orders determine a uniform clearing price; the contract verifies the clearing calculation and an oracle protection band.

“Sealed” does not hide all order information. The market, side and escrow amount are exposed by the commit transaction. Price and quantity terms protected by the commitment become public on reveal. Contract-carried orders are already revealed; carry does not make them secret again. See [Book](modules/book.md).

### Give

Support a tip or a fundraising goal. Tips are paid immediately to the campaign beneficiary. Goal donations remain in escrow until the deadline and settlement: successful goals release funds to the beneficiary; unsuccessful goals permit refunds through the route recorded for each donation.

Campaign details, totals, donation amounts and timing are public. Vault-funded donations use an adapter instead of exposing a public funding-wallet transaction directly to the campaign. See [Give](modules/give.md).

## Simple and Pro

Simple mode organizes actions around an intent, such as sending a payment or joining a sale. Pro mode exposes the individual modules and more parameters. These are interface choices, not different privacy guarantees or different contract permissions. The same approval, fee, reveal, settlement and refund conditions still apply.

## Glossary

| Term | Meaning |
|---|---|
| Vault | The application view of notes held through the registered BNB and USDT privacy pools. It is not a bank account. |
| Note | Private spending information associated with a pool commitment, including secrets needed to prove ownership. |
| Precommitment / commitment | Cryptographic values derived from note secrets and note data. Public values are not a substitute for the private recovery material. |
| Label | A deposit identifier used in the association set and screening process. |
| Scope | The pool-specific domain used to bind note derivation and withdrawal proofs to the intended pool. |
| Nullifier hash | A public spent marker that prevents the same note state from being spent twice without revealing its secret. |
| Standard amounts / units | The client's standard net note sizes. Gross funding also accounts for the applicable deposit check fee. |
| Association set | The set of labels accepted for private withdrawal, represented on-chain by a root. |
| Screen / ASP | The association-set provider: it screens deposits and supplies inclusion paths for approved labels. |
| Postman | The authorized role that publishes an association-set root to Entrypoint. A service response is not a substitute for that on-chain publication. |
| Relay | A service that submits supported transactions and pays network gas in exchange for the quoted fee. |
| Hush ID | A public stealth meta-address registered using ERC-6538; an optional short name is a directory convenience. |
| One-time address | A derived receiving address controlled by the recipient's keys. Its transactions are public even though its relationship to the recipient is not announced directly. |
| Epoch | One Book trading round, with commit, reveal and settlement stages. |
| Escrow | Funds held by a sale, order book or goal contract until its conditions permit allocation, release or refund. |
| Ragequit | The pool's public original-depositor exit. It is not available to every note holder. |

## Two boundaries to understand first

**A successful refund into the vault is a new deposit, not a guaranteed emergency exit.** Notes deposited by GiftAdapter, SealedSale, SealedBook or GiveEscrow record that contract as the original depositor. Those contracts do not expose the pool's `ragequit` path. Spending these notes depends on approval and a published root containing their label. If that access is unavailable, knowing the note secrets alone does not create a public exit.

**Local keys do not remove administrative trust.** The client is designed to derive keys and produce proofs locally. Separately, Entrypoint has an owner-authorized upgrade path and administrative controls, and other contracts have specific owner powers. Read [architecture](architecture.md) and [trust and risks](trust-and-risks.md); do not infer that operators can never affect funds or withdrawal availability.

## License scope

First-party contracts are source-available under **BUSL-1.1**, with HushCross as licensor and a **2028-10-18** change date to **GPL-2.0-or-later**, subject to the license text. Documentation is **CC BY 4.0**. Upstream and other third-party files retain their own licenses. See the [README](../README.md) for the repository's license map.
