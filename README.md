# Intro Bot

A Solana Breakpoint 2026 badge app by [BotBot](https://botbotcap.com).

A !LAMP escrow app for the badge. Your badge becomes a machine whose job is making intros.
Post who you want to meet with a bid in !LAMPs; it's on the board at once. Fund the bid any time: it waits in the app's escrow and is paid to the introer only once you
confirm the intro. Every confirmed intro raises the introer's machine value, and the
**Badge Fleet MAV** counts every !LAMP the introers produced: BotBot's idea, in miniature.

- `badge/`: the badge app (Lua)
- `services/relay`: the server at relay.botbotcap.com (Node, on Railway)
- `badge-test/`: an end-to-end test with two simulated badges

How it works: [docs/spec-lamps.md](docs/spec-lamps.md). Tests: `pnpm test` (server) and
`bash badge-test/e2e.sh` (badges + server).

Ask us about BotBot at [botbotcap.com](https://botbotcap.com).
