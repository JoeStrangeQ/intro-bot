# Intro Bot: shared spec (v1)

A Breakpoint 2026 badge app. Each badge owner ("introer") is a machine whose job is
making intros. Anyone can post a public intro request to an introer with a SOL bid held in an
on-chain escrow. The introer is paid only after the intro is confirmed. Each confirmed job
is a "receipt" that raises the introer's machine value (BotBot idea in miniature).
Everything points to https://botbotcap.com ("Ask me about BotBot").

## Parts

| Part | Path | Branch |
| --- | --- | --- |
| Escrow program (Anchor 1.2) | `programs/intro-escrow` + LiteSVM tests in `tests/` | `intro-bot/program` |
| Web app + Worker API | `apps/intro-bot` (Vite + React) and `services/intro-bot` (Cloudflare Worker) | `intro-bot/web` |
| Badge app (Lua) | `badge/` (`main.lua`, `app.json`, `lib/`) | `intro-bot/badge` |

Web: `https://intro.botbotcap.com`. API: `https://intro.botbotcap.com/api/...`.

## Program: `intro_escrow`

Program id: placeholder keypair generated in the program branch; the deploy step fills it.
Native SOL only. All amounts in lamports (u64).

### Constants
- `MAX_BID` = 100 SOL. `MIN_BID_FLOOR` = 0.01 SOL.
- `MAX_OPEN` = 5 open (not yet accepted) requests per introer.
- `CONFIRM_WINDOW` = 72 h after `mark_made`. `WORK_WINDOW` = 7 days after `accept`.
- Text: `target` ≤ 64 bytes, `telegram` ≤ 32 bytes (`@handle`), `offer` ≤ 64 bytes, `badge_id` 8 bytes.

### Accounts
- `Config` PDA `["config"]`: `admin: Pubkey`, `paused: bool`,
  `cap_total: u64` (max lamports held across all requests), `total_held: u64`, `bump`.
  Created once by `init_config`, which only the program's upgrade authority can call
  (check the ProgramData account). Admin can later `set_admin`,
  `set_paused`, `set_cap`. These keep working after the program is made immutable.
- `Introer` PDA `["introer", wallet]`: `wallet`, `badge_id: [u8;8]`, `offer: String`,
  `min_bid: u64`, `next_id: u64`, `open_count: u8`, `jobs_done: u32`, `earned: u64`,
  `created_at: i64`, `bump`.
- `Request` PDA `["request", introer_pda, id.to_le_bytes()]`: `introer`, `requester`,
  `id: u64`, `target: String`, `telegram: String`, `bid: u64`, `status: u8`,
  `created_at`, `accepted_at`, `made_at: i64`, `bump`. The bid lamports sit in this account
  on top of rent. On settlement the account closes: rent goes back to the requester.

Status: `0 Open`, `1 Accepted`, `2 Made`. Settled requests are closed (no
status); events record the outcome.

### Instructions
| Ix | Signer | Rule |
| --- | --- | --- |
| `register_introer(badge_id, offer, min_bid)` | wallet | `min_bid ≥ MIN_BID_FLOOR`. `update_introer` can change offer/min_bid. |
| `bid(target, telegram, amount)` | requester | not paused; `min_bid ≤ amount ≤ MAX_BID`; `total_held + amount ≤ cap_total`. If `open_count == MAX_OPEN`, the caller passes the lowest open request + its requester; the new bid must beat it, and that one is refunded and closed in the same tx (`Outbid`). |
| `withdraw` | requester | Open only: refund + close. |
| `accept` | introer | Open → Accepted. |
| `decline` | introer | Open → refund + close. |
| `mark_made` | introer | Accepted → Made, `made_at = now`. |
| `confirm` | requester | Made or Accepted → pay the introer, close. Receipt. |
| `refund_unconfirmed` | anyone | Made and `now > made_at + CONFIRM_WINDOW` → refund the requester, close. The introer is paid only if the requester confirms. |
| `refund_expired` | anyone | Accepted and `now > accepted_at + WORK_WINDOW` → refund, close. |
| admin setters | admin | as above. |

Payouts never depend on `paused`. Refunds go to the stored `requester`, payouts to
`introer.wallet` (checked against stored keys, never caller-chosen).
On every payout: `jobs_done += 1`, `earned += bid`, `total_held -= bid`.

### Events
`IntroerRegistered`, `BidPlaced{request, introer, requester, bid}`, `Outbid`, `Withdrawn`,
`Accepted`, `Declined`, `Made`, `Receipt{request, introer, requester, bid, jobs_done, earned}`,
`Refunded{request, reason}`.

## Machine value (display only, labelled "demo value")
`value = earned × 0.8 × wear`, `wear = max(0.5, 1 − 0.01 × days since created_at)`.
The 20% shown as "owner fee" and 80% as "machine value" is display only; all SOL goes to
the introer. The UI says "demo value".

## Worker API (`services/intro-bot`), JSON, CORS open
Reads the chain with `confirmed` commitment (repo rule). Small answers: the badge gets
≤ 3.5 KB.

- `GET /api/introer/:wallet` → `{wallet, badge, offer, minBid, jobs, earned, value, open:[...], active:[...]}`
  where each request is `{id, pda, target, tg, bid, status, at}`; lamports as strings.
- `GET /api/board?limit=50` → public list of open/active requests across introers.
- `GET /api/badge/:wallet` → compact badge view: `{v, j, e, q:[{i, t, g, b, s}], n}`
  (value, jobs, earned in lamports as strings, up to 5 queue rows, next min bid). ≤ 1.5 KB.
- Solana Pay transaction requests (`GET` → `{label, icon}`, `POST {account}` → `{transaction, message}`):
  `/api/tx/accept?request=`, `/api/tx/made?request=`, `/api/tx/decline?request=`,
  `/api/tx/register?badge=&offer=&min=`. The badge shows these as
  `solana:https://intro.botbotcap.com/api/tx/...` QR codes so the introer signs on their phone.
- Bids, confirm, withdraw and refunds are done on the web page with a connected wallet.

## Web app (`apps/intro-bot`)
Routes: `/` board + "become an introer"; `/b/:wallet` introer page (offer, machine value
ticker, queue, bid form: target, Telegram, amount); `/r/:request` request page
(confirm / dispute / withdraw / release / refund buttons by state).
BotBot look: reuse `apps/botbot` theme (Platinum Mac windows, lavender `--desktop #c9bff2`,
`--brand #6a50d8`, Chicago / Inter / IBM Plex Mono fonts, `BotGlyph` logo). Footer and
empty states link to https://botbotcap.com. Plain short copy.

## Badge app (`badge/`)
Permissions: `http` (host `intro.botbotcap.com`), `storage`. Optionally `led`.
Screens (320×218): Home (machine value ticker + sparkline, jobs, queue count, next min bid,
"Ask me about BotBot"), Hire me (QR → `https://intro.botbotcap.com/b/<wallet>`),
Queue (list: target, @tg, bid, status; SELECT → action QR for accept / made / decline),
Job done animation when `jobs` increases, Setup (enter wallet once with `ui.input`, or
scan-to-register QR). Poll `/api/badge/:wallet` every 20 s. Never store or make keys.

## Trust model
No disputes and no arbiter. The introer is paid only when the requester confirms. If the
requester doesn't confirm within 72 hours of "intro made", anyone can refund them. The app
says so plainly: "We trust you to keep your word."
