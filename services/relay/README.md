# Intro Bot relay

Solana Pay transaction requests for the badge. See `docs/spec.md`.

- `POST /tx {"message":"<hex>", "pdas"?}` → `{"url":"solana:https://relay.botbotcap.com/tx/<id>"}`
- `pdas`: addresses made from the wallet (job, introer, offer), which the badge can't know
  yet. Each is `{at, seeds}`: `at` is the key holding 32 × (2 + its index), `seeds` are hex
  or `"wallet"` (once). The relay derives them when the wallet scans.
- `GET /tx/<id>/who` → `{"wallet"}`: the wallet that scanned, so the badge learns it.
- Wallet: `GET /tx/<id>` → label and icon. `POST /tx/<id> {"account"}` → the
  transaction, with the wallet as fee payer and a fresh blockhash. Each id
  works once and lasts 10 minutes.
- `POST /connect` → `{"id","url"}`: a link that signs only a memo (unused by the badge).

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
