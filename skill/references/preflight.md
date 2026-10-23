# Preflight, setup and contracts

## `hcx preflight`

Reads status only; signs nothing. If Developer Mode is off/expired or its state is unavailable, stop before any
Binance preview or execute. Only the user may change that setting in the Binance App; re-run preflight afterwards.
This does not block `hcx wallet pending` or RPC-only `wallet reconcile`: neither needs Developer Mode, wallet sign-in
or an unlocked vault. Confirmed discard checks the signed-in wallet/App lock but does not enable Developer Mode.
See [wallet.md](wallet.md) before handling an unknown execute result.

```json
{
  "success": true,
  "data": {
    "hcxVersion": "0.1.0",
    "wallet": { "status": "CONNECTED", "address": "0x…", "devMode": { "enabled": true, "expiresAt": 1784000000, "dailyLimit": 1000, "balanceExceeded": false }, "tradeAllTokens": false },
    "vault": "unlocked",
    "services": { "relay": true, "screen": true, "indexer": true },
    "ready": { "wallet": true, "vault": true },
    "issues": []
  }
}
```

| Issue code | Meaning | What to tell the user |
|---|---|---|
| `BAW_MISSING` | `baw` is not installed | Install `@binance/agentic-wallet`. |
| `WALLET_NOT_CONNECTED` | Agentic Wallet not signed in | `baw auth signin --json`, open `urlForWeb`, confirm the pairing code in the Binance App, then `baw auth verify`. Some vault-only workflows do not use the Agentic Wallet; they still need their own plan/confirmation. |
| `DEV_MODE_OFF` / `DEV_MODE_EXPIRED` | Developer Mode is needed for every wallet transaction to HushCross contracts | Stop before preview; ask the user to enable it in the Binance App (Wallet > Agentic Wallet > Settings). It has its own daily limit and expiry. Suggest turning it off when done. |
| `TRADE_ALL_TOKENS_OFF` | Only whitelisted tokens may leave the wallet | Needed only for wallet-funded sells of non-whitelisted tokens. BNB / USDT deposits do not need it. |
| `NO_VAULT` | No vault on this machine | The user runs `hcx vault init` or `hcx vault import` in their own terminal. |
| `PASSWORD_MISSING` / `PASSWORD_WRONG` | The agent cannot unlock the vault | The user sets `HCX_PASSWORD` or `HCX_PASSWORD_FILE` in the agent's environment. |
| `SERVICE_DOWN_*` | A HushCross service did not answer | Try later; deposits still work without the relay. |

Developer Mode lets the Agentic Wallet sign contract calls that Binance has not verified. Binance shows a risk warning
for it. Validate contract targets against `hcx contracts`. An explicitly approved direct BNB payment may instead target
the user-specified recipient; token transfers must also have the approved decoded recipient and amount. Do not treat
this exception as permission for arbitrary calls or approvals.

## Install

```bash
npm install -g @binance/agentic-wallet
npm install -g https://github.com/hushcross/hushcross-protocol/releases/download/hcx-v0.1.0/hushcross-hcx-0.1.0.tgz
```

Node.js 22.12 or newer. Check with `hcx version`.

## Vault setup (the user, not the agent)

```bash
hcx vault init      # new vault: shows the recovery phrase on the terminal only, asks for a password
hcx vault import    # existing phrase, e.g. from https://hushcross.fun (compatible vault format; verify the target client version and real-chain mode)
```

Both refuse to run without an interactive terminal (`needs_terminal`). Never ask the user to paste the phrase into
the chat. After setup the user provides password access through secure local environment handling or a protected
`HCX_PASSWORD_FILE`, never by pasting a password into chat or into a recorded command.

`hcx vault status` shows the vault identity, Hush ID and meta-address.

## `hcx contracts`

The official addresses compiled into hcx (entrypoint, pools, adapters, Book, Give, Launch). A wallet plan's
`firstEffect.to` normally matches one of them or the explicitly intended token contract being approved (USDT
`0x55d398326f99059fF775485246999027B3197955` for USDT deposits). Direct BNB `pay` is permitted only to the exact user-approved recipient/value.
Every real wallet execute requires the user to review parsedTx, risks and authorityChanges and personally type the
current requestId in a terminal. Null authorityChanges is not proof that permissions are unchanged. An agent must not
create a PTY or enter the ID for the user; headless execution is refused.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `HCX_PASSWORD` / `HCX_PASSWORD_FILE` | — | Unlocks the vault. Never passed as a flag. |
| `HCX_HOME` | `~/.hushcross` | Encrypted vault, caches, and the separate unencrypted wallet activity journal. |
| `HCX_BAW_BIN` | `baw` | Path of the Agentic Wallet CLI. |
| `HCX_RPC_URL`, `HCX_RELAY_URL`, `HCX_SCREEN_URL`, `HCX_INDEXER_URL`, `HCX_META_URL` | hushcross.fun services | Only change when the user asks. |

The first command of a session may take up to a minute while public contract history is cached in `HCX_HOME/cache`.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
