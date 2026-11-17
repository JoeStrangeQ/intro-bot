# Intro Bot server

Keeps the intro board and pays out of the app's !LAMP escrow. See `docs/spec-lamps.md`.

## Run

```sh
ESCROW_KEY=... APP_KEY=... DATA_DIR=./data node src/server.ts
```

| Variable | What |
| --- | --- |
| `ESCROW_KEY` | the escrow's key (payouts, ledger) |
| `APP_KEY` | the app's server key (meets) |
| `DATA_DIR` | where `state.json` lives (a Railway volume) |
| `PUBLIC_URL` | `https://relay.botbotcap.com`: the URL the badge server signs |
| `BADGE_API` | `https://badge-api.solana.com` (tests point it at a fake) |

## Hosting

Railway project `intro-bot-relay`, service `relay`, domain `relay.botbotcap.com`. Keys are
Railway variables only.

## Tests

`pnpm test` here; `bash badge-test/e2e.sh` from the repo root for the badges.
