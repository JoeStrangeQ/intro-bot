# Intro Bot relay

Solana Pay transaction requests for the badge. See `docs/spec.md`.

- `POST /tx {"message":"<hex>"}` → `{"url":"solana:https://relay.botbotcap.com/tx/<id>"}`
- Wallet: `GET /tx/<id>` → label and icon. `POST /tx/<id> {"account"}` → the
  transaction, with the wallet as fee payer and a fresh blockhash. Each id
  works once and lasts 10 minutes.
- Connect: `POST /connect` → `{"id","url"}`. The wallet that scans `url` signs a
  memo; the badge reads its address from `GET /tx/<id>/who` → `{"wallet"}`.

Only legacy messages, one signer (32 × `0x01` at key 0), and only
intro_escrow instructions are accepted.

## RPC

`RPC_URL` is set per environment. Local dev uses public devnet from
`wrangler.toml`. Production has no default; set it as a secret:

```sh
wrangler secret put RPC_URL --env production
```

Without it the relay answers 502 instead of using the wrong cluster.

## Run

```sh
pnpm test      # vitest
pnpm dev       # wrangler dev
```

## Hosting

Runs on Railway (`node src/server.ts`, Node 24+) at relay.botbotcap.com. Links and rate
limits are kept in memory, so run one instance. `RPC_URL` is a Railway variable.
