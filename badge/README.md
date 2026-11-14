# Intro Bot badge app

Shows your intro queue on your Breakpoint badge. People scan your badge to bid for an
intro. You accept, decline or mark intros made by scanning a QR with your phone wallet.
The badge never holds keys.

## Screens

Use LEFT / RIGHT to move between screens. CANCEL goes back, or exits from a main screen.

- **Home**: machine value (a demo value) with a small chart, jobs done, queue size,
  next min bid, and "Ask me about BotBot".
- **Hire me**: a QR to your page, `https://intro.botbotcap.com/b/<wallet>`.
- **Queue**: up to 5 requests. SELECT one, pick Accept / Intro made / Decline, and scan
  the QR with your phone wallet to sign.
- **Setup**: enter your wallet, show a QR to register as an introer, turn demo mode on
  or off, clear the wallet.

When your job count goes up, the badge plays a short "JOB DONE!" animation and flashes
its lights. It checks the server every 20 seconds and keeps the last data when offline.

## Try it

1. Open https://solana.com/breakpoint/badge/apps/submit and sign in.
2. Drop this folder on the editor, without `test/` (it is only for local checks).
3. Press **Try in emulator**. In Setup, turn on **Demo mode** to see it work with fake
   data, or enter your wallet to use the live server.

Calls to `intro.botbotcap.com` need your account to have X linked while testing.

## Publish

Link X at `/profile`, then press **Publish** on the submit page. The store compiles
every `.lua` file and checks the code first.

Permissions: `http` (host `intro.botbotcap.com`) and `led`. Storage is always allowed,
so it is not listed.

## Local checks

```sh
for f in main.lua lib/*.lua; do luac -p "$f"; done
lua test/sim.lua
```

`test/sim.lua` stubs the badge API, walks every screen and key, tries bad answers, and
checks the limits (UI objects, label and QR sizes, storage, instructions per callback).
