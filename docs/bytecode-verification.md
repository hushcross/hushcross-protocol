# Runtime bytecode comparison

Snapshot: BSC chain **56**, block **128359724**, **2026-10-18T12:09:02+00:00**.

The exported source was rebuilt with Solidity 0.8.28, optimizer 200, Cancun, no via-IR and no appended CBOR metadata. Every byte matched after compiler-defined constructor/library bindings were resolved and checked. No arbitrary ranges were ignored.

| Contract | Mainnet address | Runtime bytes | Result | Bindings checked |
|---|---|---:|---|---|
| Entrypoint (proxy) | [`0x202bdabf86e6b197db716ee7f0c5a3e325d7058a`](https://bscscan.com/address/0x202bdabf86e6b197db716ee7f0c5a3e325d7058a#code) | 109 | MATCH | No substitutions required |
| BNB privacy pool | [`0x23c49d9044585b69e37f3eca04da1237b8a2da1d`](https://bscscan.com/address/0x23c49d9044585b69e37f3eca04da1237b8a2da1d#code) | 6165 | MATCH | ASSET, SCOPE, ENTRYPOINT, WITHDRAWAL_VERIFIER, RAGEQUIT_VERIFIER, PoseidonT3, PoseidonT4 |
| USDT privacy pool | [`0xc8df3f06ab3114e56b5fa323efc5372fc0e719bd`](https://bscscan.com/address/0xc8df3f06ab3114e56b5fa323efc5372fc0e719bd#code) | 6421 | MATCH | ASSET, SCOPE, ENTRYPOINT, WITHDRAWAL_VERIFIER, RAGEQUIT_VERIFIER, PoseidonT3, PoseidonT4 |
| HushSendAdapter | [`0x141e36a85c71b4945965ea5a73a15270a8147296`](https://bscscan.com/address/0x141e36a85c71b4945965ea5a73a15270a8147296#code) | 4207 | MATCH | ENTRYPOINT, ANNOUNCER |
| GiftAdapter | [`0xdc7339e0e562dbfcfc59506742241907f36f90ba`](https://bscscan.com/address/0xdc7339e0e562dbfcfc59506742241907f36f90ba#code) | 5257 | MATCH | ENTRYPOINT |
| LaunchFactory | [`0x698fd53f18c6e73398877bdb919bf9287ea0adeb`](https://bscscan.com/address/0x698fd53f18c6e73398877bdb919bf9287ea0adeb#code) | 15345 | MATCH | entrypoint, wbnb, usdt, pancakeFactory, positionManager, saleDeployer |
| LaunchAdapter | [`0x16312f4a722a937ad756378f16a07c8506428676`](https://bscscan.com/address/0x16312f4a722a937ad756378f16a07c8506428676#code) | 4039 | MATCH | entrypoint, factory |
| SealedBook | [`0x2efa789972cadce7a6a8d88b5afc768217f67fc7`](https://bscscan.com/address/0x2efa789972cadce7a6a8d88b5afc768217f67fc7#code) | 24075 | MATCH | entrypoint, wbnb, usdt, BookClearing, BookListing, BookOracle, VaultNotes |
| BookAdapter | [`0x5cc7abdcc9617e290ae9f9ad85729a33afc29af3`](https://bscscan.com/address/0x5cc7abdcc9617e290ae9f9ad85729a33afc29af3#code) | 5207 | MATCH | entrypoint, book, wbnb |
| GiveRegistry | [`0xdc276fd8ad4800d7ee3d26940674ab4e5856d33e`](https://bscscan.com/address/0xdc276fd8ad4800d7ee3d26940674ab4e5856d33e#code) | 3690 | MATCH | usdt |
| GiveEscrow | [`0x9db39f793ac11d9deea6f832736735a86daddf5b`](https://bscscan.com/address/0x9db39f793ac11d9deea6f832736735a86daddf5b#code) | 10889 | MATCH | registry, entrypoint, usdt |
| GiveAdapter | [`0x88d6cb590253df9ea6565160c65988d2cbca1358`](https://bscscan.com/address/0x88d6cb590253df9ea6565160c65988d2cbca1358#code) | 5159 | MATCH | entrypoint, escrow |
| Entrypoint implementation | [`0x64905421a7d474bea90de1e674a4bb3af1690b06`](https://bscscan.com/address/0x64905421a7d474bea90de1e674a4bb3af1690b06#code) | 10982 | MATCH | __self |
| WithdrawalVerifier | [`0x269fe407249f54c56d2998c47290d95aa04c2963`](https://bscscan.com/address/0x269fe407249f54c56d2998c47290d95aa04c2963#code) | 1947 | MATCH | No substitutions required |
| CommitmentVerifier | [`0x40889fe897ea3d4c61b1ee776b6d2a6fafa0acea`](https://bscscan.com/address/0x40889fe897ea3d4c61b1ee776b6d2a6fafa0acea#code) | 1582 | MATCH | No substitutions required |
| SaleDeployer | [`0x9ce2651e26c78691b73577bf6e0c46dec6f46936`](https://bscscan.com/address/0x9ce2651e26c78691b73577bf6e0c46dec6f46936#code) | 24259 | MATCH | No substitutions required |
| PoseidonT3 | [`0xa6e3d33abef457db3a2f1504c91eee1a77375891`](https://bscscan.com/address/0xa6e3d33abef457db3a2f1504c91eee1a77375891#code) | 16413 | MATCH | library-self-address |
| PoseidonT4 | [`0x72f8c6de40a45a6f49f7f52dd2c73aae1819bd66`](https://bscscan.com/address/0x72f8c6de40a45a6f49f7f52dd2c73aae1819bd66#code) | 12427 | MATCH | library-self-address |
| BookClearing | [`0xe02f861487df9ef27777b7ccbbe7d1d336762df9`](https://bscscan.com/address/0xe02f861487df9ef27777b7ccbbe7d1d336762df9#code) | 5321 | MATCH | library-self-address |
| BookListing | [`0x569c3bfcfa90f3df2149087934ff7b20740a28b5`](https://bscscan.com/address/0x569c3bfcfa90f3df2149087934ff7b20740a28b5#code) | 2388 | MATCH | library-self-address |
| BookOracle | [`0xb2d2395adce4f95033e47974cbf3ecb8cc580adc`](https://bscscan.com/address/0xb2d2395adce4f95033e47974cbf3ecb8cc580adc#code) | 3614 | MATCH | library-self-address |
| VaultNotes | [`0x2b0b19e841b64af09001f80a028414ff0f06d508`](https://bscscan.com/address/0x2b0b19e841b64af09001f80a028414ff0f06d508#code) | 2969 | MATCH | library-self-address |

## Interpretation

- The proxy and its implementation are separate rows; the implementation was resolved from the EIP-1967 slot at the same snapshot.
- Library addresses were discovered from linked code positions, then each library runtime was checked recursively, including its self-address guard.
- Public immutables were cross-checked with getters and known bindings; pool scope was independently recomputed from the upstream constructor formula.
- The generated first-party deployment artifacts do not contain the complete creation bytecode of either GPL verifier; the verifier sources and separate artifacts keep their original license.
- This is not a check of every historical creation transaction, explorer-hosted source text or dynamically created sale/token/vesting instance.
- External oracles, routers and standard singleton deployments are not included in these 22 rows. No chain transaction or deployment was performed.
- Matching code is not a guarantee about security, administrative behavior, RPC honesty, service uptime or future upgrades.

Reproduce the procedure with the [verification guide](verify.md).
