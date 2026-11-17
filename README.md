# Intro Bot

A Solana Breakpoint 2026 badge app by [BotBot](https://botbotcap.com).

A !LAMP escrow app for the badge. Your badge becomes a machine whose job is making intros.
Post who you want to meet with a bid in !LAMPs. Every bid is paid into escrow when posted, so
everything on the board is backed; it goes to the introer only once you confirm the intro. Every confirmed intro raises the introer's machine value, and the
**Badge Fleet MAV** counts every !LAMP the introers produced: BotBot's idea, in miniature.

## Rewards

Introers get a **50 !LAMP bonus** for each confirmed intro, on top of the bid.

- Up to 100 !LAMPs a day per person (two bonuses).
- One bonus per pair of people, ever.
- The intro needs a verified badge meet, and the introer needs X linked.
- The app's daily limit is set by the badge team.

- `badge/`: the badge app (Lua)
- `services/relay`: the server at relay.botbotcap.com (Node, on Railway)
- `badge-test/`: an end-to-end test with two simulated badges

How it works: [docs/spec-lamps.md](docs/spec-lamps.md). Tests: `pnpm test` (server) and
`bash badge-test/e2e.sh` (badges + server).

Ask us about BotBot at [botbotcap.com](https://botbotcap.com).
