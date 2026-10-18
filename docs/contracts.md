# Contract reference

This is a guide to the disclosed contract source, not a substitute for reading it. The current BSC mainnet deployment and explorer links are in the [README](../README.md); [verify.md](verify.md) explains independent verification. The public website currently presents demo data, which must not be confused with contract state.

## Vault and upstream code

The vault uses a pinned Privacy Pools source snapshot. HushCross's product adapters compose with its interfaces rather than replacing the proof system. The upstream snapshot and original licenses are under [contracts/vendor](../contracts/vendor/). The generated verifiers have their own file-level license notices; do not assume that one repository-level license covers every dependency.

| Component | Responsibility and principal calls | Authority and important events |
|---|---|---|
| [Entrypoint](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/Entrypoint.sol) and its ERC-1967 proxy | Register pools, accept native/token `deposit`, route direct `relay` withdrawals, expose `assetConfig`, `scopeToPool` and association roots. | `updateRoot` requires the ASP postman role. The owner role controls pool registration/removal/configuration, `windDownPool`, `withdrawFees`, role administration and UUPS upgrade authorization. Events include `RootUpdated`, `PoolRegistered`, `PoolRemoved`, `PoolConfigurationUpdated`, `Deposited`, `WithdrawalRelayed`, `FeesWithdrawn` and `PoolWindDown`. |
| [PrivacyPool](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/PrivacyPool.sol), [PrivacyPoolSimple](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/implementations/PrivacyPoolSimple.sol) and [PrivacyPoolComplex](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/implementations/PrivacyPoolComplex.sol) | Common proof/state logic, with native-asset and token transfer implementations. `withdraw` validates the designated processor, proof context, known state root, latest ASP root and spent marker. `ragequit` is the original-depositor public exit. | Deposits and wind-down are constrained to Entrypoint. Ragequit requires the original depositor and a valid current commitment proof. Events: `Deposited`, `Withdrawn`, `Ragequit`, `PoolDied`. |
| [State](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/State.sol) and [ProofLib](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/lib/ProofLib.sol) | Pool tree, root history, scope, depositor labels and spent-nullifier bookkeeping; proof signal decoding. | `LeafInserted` makes state-tree updates observable. An old or mismatched root is not automatically an acceptable withdrawal root. |
| [WithdrawalVerifier](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/verifiers/WithdrawalVerifier.sol) and [CommitmentVerifier](../contracts/vendor/privacy-pools-core/packages/contracts/src/contracts/verifiers/CommitmentVerifier.sol) | Verify the withdrawal and commitment proofs consumed by the pools. | Separately deployed proof verifiers. Retain their original source and license notices; their presence does not establish system-wide security assurance. |

**Upgrade boundary:** Entrypoint is upgradeable. The owner role can change the implementation and control other privileged roles. Local possession of a recovery phrase does not remove this administrative trust. Inspect the actual implementation and role holders, not just the proxy address.

## Send and Gift

| Component | Calls and checks | Events and boundaries |
|---|---|---|
| [HushSendAdapter](../contracts/src/send/HushSendAdapter.sol) | `send` consumes a proof bound to this processor, checks the registered pool and relay fee, and pays the specified recipient. A supplied gas stipend is forwarded to the recipient. When the public-key and metadata fields are supplied, it calls the configured announcer. | `HushSent`. Entrypoint and announcer references are constructor-bound. A caller with valid proof-bound data can submit; this is not an owner-controlled payment account. The normal-address path does not emit a stealth announcement. |
| [GiftAdapter](../contracts/src/send/GiftAdapter.sol) | `gift` spends a note into a bounded list of new precommitments in the same pool, plus the specified fee and remainder. It rejects duplicate precommitments and invalid split amounts. Used both to create gifts and to claim into another vault. | `GiftFunded`. It has no recipient-only gift entitlement, expiry timer or user-facing ragequit method. Successfully created notes record the adapter as depositor. |
| [ERC5564Announcer](../contracts/src/standards/ERC5564Announcer.sol) and [interface](../contracts/src/standards/IERC5564Announcer.sol) | Publish a scheme identifier, receiving address, ephemeral public key and metadata through `announce`. | `Announcement` is public. Announcements do not contain the recipient's private spending key or authenticate arbitrary marketing claims. |
| [ERC6538Registry](../contracts/src/standards/ERC6538Registry.sol) and [interface](../contracts/src/standards/IERC6538Registry.sol) | Register public stealth meta-addresses with `registerKeys`; support signature-authorized `registerKeysOnBehalf` and replay-control nonces. | `StealthMetaAddressSet`, `NonceIncremented`. A registration and its public keys are visible. Reference implementations in the source tree do not imply that those local references are the external standard instances used by mainnet; use the deployment table. |

Adapters check the balance change caused by the operation and leave any pre-existing balance unchanged. This avoids using a stranger's unsolicited transfer as the operation's funds; it does not promise recovery of funds sent directly to an adapter outside its intended entry point.

## Launch

| Component | Principal calls | Permissions and events |
|---|---|---|
| [LaunchFactory](../contracts/src/launch/LaunchFactory.sol) | `createSale`, `validateParams`, `isSale`, `creatorOf`, `setProfile`, `profileOf`, `collectFees`. Deploys a token, sale and, where needed, creator vesting wallet. | Ownable2Step owner can change the treasury used for newly created sales and set the launch adapter once. Only the recorded creator can set or clear that sale's profile pointer. Events: `SaleCreated`, `SaleDeployed`, `SaleProfileSet`, `TreasuryUpdated`, `LaunchAdapterSet`, plus inherited ownership events. |
| [SaleDeployer](../contracts/src/launch/SaleDeployer.sol) | `deploy` holds SealedSale creation code separately from LaunchFactory. | Permissionless, but the supplied factory must equal the caller. Deployment through this helper alone does not make a sale official: `LaunchFactory.isSale` is the relevant registry. |
| [HushToken](../contracts/src/launch/HushToken.sol) | Fixed-supply ERC-20 with EIP-2612 permit. Supply is created in the constructor. | No post-construction mint function, owner, transfer tax, blacklist or pause is added by HushToken. Inherited ERC-20 transfer/approval events apply. This statement does not apply to arbitrary tokens outside this contract. |
| [SealedSale](../contracts/src/launch/SealedSale.sol) | `commit`, `reveal`, `finalize`, `abort`, `claim`, `lateReveal`, `claimToPayout`, `claimProceeds`, `collectFees`; allocation and clearing views. | Phase and commitment checks control bids. Anyone can propose a valid settlement or trigger the timeout abort when eligible. Claims pay the recorded recipient; `claimToPayout` requires that recipient, and `claimProceeds` requires the creator. Events include `BidCommitted`, `BidRevealed`, `BidValidity`, `BidEvicted`, `BidDisplaced`, `SaleCleared`, `SaleFailed`, `BidClaimed`, `LiquidityAdded`, `CreatorProceedsClaimed` and `FeesCollected`. |
| [LaunchAdapter](../contracts/src/launch/LaunchAdapter.sol) | `fundBid` connects a valid pool withdrawal to a registered sale and checks quote-asset and fee consistency. | Constructor-bound Entrypoint and factory; proof-bound processor data. Emits `BidFunded`. Only bids identified by the sale as vault-funded can take its vault-refund route. |

[LaunchClearing](../contracts/src/launch/LaunchClearing.sol) checks the proposed uniform-price result and computes allocations and liquidity. [LaunchTypes](../contracts/src/launch/LaunchTypes.sol) defines parameters, constants and records. [BidHeap](../contracts/src/launch/sale/BidHeap.sol) manages bounded live-bid selection. [QuoteTransfers](../contracts/src/launch/sale/QuoteTransfers.sol) handles quote transfers and refund-note creation, including `VaultDeposit` and `VaultDepositFailed`. [LiquiditySeeder](../contracts/src/launch/sale/LiquiditySeeder.sol) handles the PancakeSwap V3 pool/position interaction and authenticated swap callback.

The LP position remains with the sale contract. Collecting its trading fees is not withdrawal of its liquidity. Public-wallet bids receive ordinary refunds; vault-funded refunds may create new notes. Specific failed deposit attempts may become a public remainder, while an empty-data failure reverts rather than silently forcing a public payout.

## Book

| Component | Principal calls | Permissions and events |
|---|---|---|
| [SealedBook](../contracts/src/book/SealedBook.sol) | `commit`, `reveal`, `settle`, `settleNoCross`, `voidExpired`, `claim`, `claimToRecipient`, `claimUnrevealed`, plus market, epoch and preview views. | Owner lists markets, sets minimum escrow and sets the adapter once. Ownership transfer requires `acceptOwnership`. Settlement is permissionless but must satisfy contract checks. For a vault-funded order, only its recipient may choose `claimToRecipient`. Events: `PairListed`, `MinEscrowSet`, `OrderCommitted`, `OrderRevealed`, `OrderDisplaced`, `EpochSettled`, `EpochVoided`, `OrderClaimed`, `OrderCarried`, `CarrySkipped`, `ReferenceRead`, `FeesTaken` and ownership events. |
| [BookAdapter](../contracts/src/book/BookAdapter.sol) | `fundOrder` binds a pool withdrawal to an order commitment. Checks the market side, asset, fee and balance changes; wraps BNB when the market needs WBNB. | Constructor-bound Entrypoint, Book and WBNB references. Emits `OrderFunded`. It does not make every listed base asset a supported privacy-pool asset. |
| [BookClearing](../contracts/src/book/BookClearing.sol) | Linked clearing-certificate evaluation, no-cross diagnosis and side accounting. | Runs as contract code, not as a trusted off-chain matching operator. A proposed result must satisfy the on-chain checks. |
| [BookOracle](../contracts/src/book/BookOracle.sol) | Linked reference-price calculation from configured Chainlink feeds or PancakeSwap TWAP data. | Settlement depends on acceptable oracle data and the protection band. The library does not guarantee oracle availability or market fairness. |
| [BookListing](../contracts/src/book/BookListing.sol) | Linked market initialization, oracle-source checks and initial minimum escrow calculation. | Invoked through SealedBook's owner-controlled listing flow. |
| [VaultNotes](../contracts/src/book/VaultNotes.sol) | Linked splitting and deposit of eligible unused escrow into vault notes. | Emits `VaultNote` or `VaultNoteFailed`. Some unsuccessful deposit amounts return as public remainder; an empty-data failure reverts. It does not expose ragequit for successfully opened notes. |

[BookMath](../contracts/src/book/BookMath.sol) and [BookTypes](../contracts/src/book/BookTypes.sol) define arithmetic, commitments, states and constants. [IBookOracles](../contracts/src/book/interfaces/IBookOracles.sol) describes external oracle interfaces.

The commit call already exposes market, side and escrow. Revealed order terms remain public when a contract carries that order. Fill proceeds always go to the recorded recipient. Only eligible **unused escrow belonging to the vault-funded order itself**, not counterparty proceeds, is deposited back into the vault.

## Give

| Component | Principal calls | Permissions and events |
|---|---|---|
| [GiveRegistry](../contracts/src/give/GiveRegistry.sol) | Campaign records and validation; `campaign`, `campaignCount`, `create`, `linkEscrow`. | The deployer can link the escrow once; only that escrow can create registry records. There is no general registry-owner withdrawal action. Campaign creation events are emitted by GiveEscrow. |
| [GiveEscrow](../contracts/src/give/GiveEscrow.sol) | `createCampaign`, `donate`, `donateFromAdapter`, `settle`, `release`, `refund`, `verifyReceipt` and accounting views. Tips pay immediately; goals retain escrow until their outcome. | The deployer links the adapter once. The adapter-only donation route is distinct from public funding. Any caller may execute eligible settlement/release/refund actions, but payouts follow the recorded beneficiary or refund data. Events: `CampaignCreated`, `Donated`, `CampaignSettled`, `FundsReleased`, `Refunded`, `VaultNoteOpened`, `VaultNoteSkipped`. |
| [GiveAdapter](../contracts/src/give/GiveAdapter.sol) | `fund` spends an approved pool note into the selected campaign, paying the bound relay fee and recording receipt/refund information. | Checks the registered pool, matching campaign asset and proof-bound processor. Emits `GiveFunded`. |

[GiveMath](../contracts/src/give/GiveMath.sol) and [GiveTypes](../contracts/src/give/GiveTypes.sol) contain refund allocation arithmetic and shared types. A receipt hash is public. Disclosing its secret to prove a donation also discloses that secret to the party performing the verification.

## Refund authority is not note-exit authority

A contract can release escrow or choose a permitted direct payout **before** new notes are created. That is distinct from exiting an already-created pool note. GiftAdapter, SealedSale, SealedBook and GiveEscrow have no user-callable ragequit forwarding function. Their successfully deposited notes require Screen approval and publication in the latest association root. See [trust and risks](trust-and-risks.md).

## Deployment and linked dependencies

[DeployAll.s.sol](../contracts/script/DeployAll.s.sol) wires the vault and product contracts and retains an explicit mainnet confirmation guard. [DeployVault.s.sol](../contracts/script/DeployVault.s.sol) contains the vault deployment helper used by DeployAll; the product wiring is in DeployAll itself. These are executable deployment tools, not required steps for inspecting an existing deployment. Do not broadcast them merely to verify source.

BookClearing, BookOracle, BookListing and VaultNotes use externally linked library calls. Poseidon dependencies support the privacy-pool tree/proof primitives and must be linked as required by the selected compiled artifacts. Library addresses, immutable constructor values, compiler settings and proxy implementation identity all matter in bytecode comparison. Solidity `private` visibility does not encrypt storage.

External tokens, oracle feeds, ERC-5564/6538 instances and PancakeSwap V3 contracts are distinct deployments with their own assumptions. Check their configured addresses in [DeployAll constants](../contracts/script/DeployAll.s.sol) and the deployed contracts’ getters. They are not part of the first-party address or bytecode-comparison tables.

First-party contract licensing is **BUSL-1.1**, changing to **GPL-2.0-or-later** on **2028-10-18** under the license terms. This is a **source-available** publication; third-party notices remain in force. This document is **CC BY 4.0**.
