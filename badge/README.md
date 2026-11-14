# Intro Bot badge app

Get paid for intros at Breakpoint, or bid for one. Both sides run on the badge.

- **Introers** show their offer, machine value and queue. They accept, decline or mark
  intros made.
- **Requesters** find introers nearby or by wallet, bid SOL, then confirm, withdraw or
  refund.

The bid waits in an on-chain escrow. The introer is paid only when the requester
confirms. With no confirm within 72 hours of "intro made", the requester can get a
refund. We trust you to keep your word.

The badge never holds keys. It builds each transaction, the relay turns it into a QR,
and you sign on your phone wallet.

## Screens

LEFT / RIGHT moves between screens. CANCEL goes back, or exits from a main screen.

- **Home**: machine value (a demo value) with a small chart, jobs, open requests, min
  bid, "Ask me about BotBot".
- **My queue**: requests to you. SELECT one to accept, decline or mark made.
- **Hire me**: your offer, and "Paid only when you confirm." Badges nearby can find you.
- **Find**: introers nearby (over the mesh), seen before, or by wallet. SELECT one to bid.
- **My requests**: your bids. Confirm, withdraw, or refund when the time is up.
- **Setup**: your wallet (public address only), register or update your offer, demo mode.

When your job count goes up, the badge plays "JOB DONE!" and flashes its lights.

## How it talks to the chain

- Reads with `rpc` on devnet (`getAccountInfo`, `getMultipleAccounts`), every 20 s,
  within 30 calls a minute. The badge's `rpc` has no `getProgramAccounts`, so requests
  are found by address (`["request", introer, id]` for recent ids) and introers by the
  mesh, a typed wallet, or the program's list of the 32 latest introers.
- Posts each transaction message to `https://relay.botbotcap.com/tx` and shows the
  `solana:` link it returns as a QR.
- Watches the changed account until the step lands.
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
`relay.botbotcap.com`), `mesh`, `led`. Storage is always allowed.

## Local checks

From the repo root:

```sh
for f in badge/main.lua badge/lib/*.lua; do luac -p "$f"; done
lua badge-test/sim.lua
```

The test lives outside `badge/` so it isn't uploaded. It needs `python3` (`pda.py`).
It also checks the badge's instructions and account decoding against the program's
fixtures in `../intro-bot-program/tests/fixtures` (or set `FIXTURES=<dir>`).
