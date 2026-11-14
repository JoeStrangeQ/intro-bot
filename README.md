# Intro Bot

A Solana Breakpoint 2026 badge app by [BotBot](https://botbotcap.com).

Your badge becomes a machine whose job is making intros. Anyone can post a public
intro request with a SOL bid. The bid waits in an on-chain escrow and is paid to
the introer only once the intro is confirmed. Every confirmed intro is a receipt
that raises the badge's machine value: BotBot's idea, in miniature.

- `programs/intro-escrow`: the escrow program (Anchor)
- `apps/intro-bot`: the web app at intro.botbotcap.com
- `services/intro-bot`: the API (Cloudflare Worker)
- `badge/`: the badge app (Lua)

See [docs/spec.md](docs/spec.md). Ask us about BotBot at [botbotcap.com](https://botbotcap.com).
