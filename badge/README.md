# Intro Bot badge app

Request an intro at Breakpoint. Say who you want to meet, their company and your bid in
SOL. Introers offer to make the intro. You talk on Telegram, pick one, and they are paid
only when you confirm. We trust you to keep your word.

The bid waits in an on-chain escrow. The badge never holds keys: it builds each
transaction, the relay turns it into a QR, and you sign on your phone wallet.

## Screens

LEFT / RIGHT moves between screens. CANCEL goes back, or exits from a main screen.

- **Request an intro** (opens here): who, company, bid, Telegram (remembered), then a QR.
  "Your Telegram is shown to people who offer."
- **Intro board**: the newest jobs: who, company, bid, offers. SELECT one to offer. After
  you offer, you see the requester's Telegram.
- **My jobs**: your jobs. Open: the offer pool (name, jobs done, earned); SELECT one to
  approve, or cancel. Then confirm, or refund when the time is up.
- **My offers**: jobs you offered on. When you're picked: "Intro made". Closed jobs: get
  your offer rent back.
- **Profile**: your wallet, register as an introer, machine value (a demo value), demo mode,
  the botbotcap.com QR and "Robots that earn → botbotcap.com".

When a job you made is confirmed, the badge plays "JOB DONE!" and flashes its lights.

## How it talks to the chain

- Reads with `rpc` (`getAccountInfo`, `getMultipleAccounts`), every 20 s, within 30 calls
  a minute: the Board account (a ring of the newest jobs), your jobs by nonce, and the jobs
  you offered on. A job is ~700 bytes, so 3 are read per call.
- Posts each transaction message to `https://relay.botbotcap.com/tx` and shows the
  `solana:` link it returns as a QR, then watches the changed account. If a step doesn't
  land, SELECT retries it.
- Program id and cluster are at the top of `lib/escrow.lua`.

## Try it

1. Open https://solana.com/breakpoint/badge/apps/submit and sign in.
2. Drop this `badge/` folder on the editor.
3. Press **Try in emulator**. Turn on **Demo mode** in Setup to try every screen with no
   network, or enter your wallet to use devnet.

Testing `rpc` and `http` needs your account to have X linked. Needs Solana OS 2.1.0 or
later (the `solana` module).

## Publish

Link X at `/profile`, then press **Publish**. Permissions: `rpc`, `http` (host
`relay.botbotcap.com`), `led`. Storage is always allowed.

## Local checks

From the repo root:

```sh
for f in badge/main.lua badge/lib/*.lua; do luac -p "$f"; done
lua badge-test/sim.lua
```

The test lives outside `badge/` so it isn't uploaded. It needs `python3` (`pda.py`).
It also checks the badge's instructions and account decoding against the program's
fixtures in `tests/fixtures` (or set `FIXTURES=<dir>`).

## Local end-to-end

```sh
pnpm install
pnpm e2e
```

Runs the whole flow on your machine, nothing public: the program on a local chain,
the relay under `wrangler dev`, `badge-test/wallet.mjs` as the phone wallet, and
`badge-test/e2e.lua` using the badge's own `lib/` code. Throwaway keys go in
`target/e2e` (gitignored).

It runs twice: on `solana-test-validator` (program loaded upgradeable), then on
`surfpool --offline` with time travel for withdraw (24h) and both refunds (72h, 7 days).
Needs the Solana CLI, `cargo build-sbf`, surfpool, Lua, Node, Python 3 and curl, with
ports 8899, 8787, 18899 and 18787 free.
