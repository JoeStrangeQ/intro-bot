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
| Solana Pay relay | `services/relay` (Cloudflare Worker, no UI) | `intro-bot/web` |
| Badge app (Lua) | `badge/` (`main.lua`, `app.json`, `lib/`) | `intro-bot/badge` |

Relay: `https://relay.botbotcap.com` (Solana Pay transaction requests only).

## Program: `intro_escrow`

Program id: `GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC` (keypair kept outside the repo).
IDL: `idl/intro_escrow.json`. Deploy steps: `docs/deploy.md`.
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

### Program details (filled in by the program branch)
- `init_config(arbiter, cap_total)`: the signer must be the upgrade authority and becomes `admin`.
  Accounts: `config, authority, program, program_data, system_program`.
- `bid` accounts: `config, introer, request, requester, lowest?, lowest_requester?, system_program`.
  `request` is the PDA for `introer.next_id`. When the queue is not full, pass the program id for
  `lowest` / `lowest_requester` (Anchor "none"); they are ignored.
- **Full queue (addition):** besides `lowest` + `lowest_requester`, pass the other 4 open
  requests of the introer as remaining accounts (read-only). This proves `lowest` really is the
  lowest. The new bid must be strictly higher than `lowest.bid`.
- `target` must not be empty. `min_bid` must also be ≤ `MAX_BID`.
- Payout and refund ixs take `wallet` (= `introer.wallet`) and `requester` (= `request.requester`)
  accounts; wrong keys fail.
- Event fields: `IntroerRegistered{introer, wallet, badge_id, min_bid}`,
  `Outbid{request, requester, bid, new_bid}` (request = the refunded one), `Withdrawn{request}`,
  `Accepted{request}`, `Declined{request}`, `Made{request, made_at}`, `Disputed{request}`.
  `Refunded{request, reason}` is emitted on every refund: `0` withdrawn, `1` declined,
  `2` outbid, `3` expired, `4` arbiter.
- Errors: see `EscrowError` in the IDL.

## Machine value (display only, labelled "demo value")
`value = earned × 0.8 × wear`, `wear = max(0.5, 1 − 0.01 × days since created_at)`.
The 20% shown as "owner fee" and 80% as "machine value" is display only; all SOL goes to
the introer. The UI says "demo value".

## No web app: everything on the badge
Both sides use the badge. The introer runs Intro Bot to show their offer and queue; the
requester runs it to browse introers (on-chain list, or nearby badges over the mesh), bid,
confirm, withdraw or refund. The badge reads the chain itself with `rpc`
(`getProgramAccounts` with `memcmp` filters and `dataSlice`, `getAccountInfo`).

The badge can't sign. Every action is built on the badge as a transaction message and signed
on the person's phone wallet through a Solana Pay transaction request QR, as the badge docs
describe ("Build on the badge, sign on a phone"). Solana Pay needs an https endpoint the
wallet can fetch, so there is one tiny stateless **relay** (`services/relay`, Cloudflare
Worker, no UI): the badge POSTs the message, gets back a `solana:https://relay.botbotcap.com/tx/<id>`
link, the wallet GETs/POSTs it, and the relay fills the wallet's address and a fresh
blockhash. It holds a message for at most 10 minutes (KV TTL), never holds keys or funds,
and can't change accounts or amounts beyond the signer placeholder.

Account layout must keep fixed-size fields first so `memcmp` and `dataSlice` work:
`introer`/`requester` pubkeys, ids, amounts, status and timestamps before any text.
Text fields are fixed-size byte arrays (`target: [u8;64]`, `telegram: [u8;32]`,
`offer: [u8;64]`), zero-padded, so offsets never move.

## Badge app (`badge/`)
Permissions: `rpc`, `http` (host `relay.botbotcap.com`), `storage`, `mesh`, `led`.
Never store or make keys; the user's wallet address (public) is entered once.
- **Introer:** Home (machine value "demo value" ticker + sparkline, jobs, open queue, min bid,
  "Ask me about BotBot · botbotcap.com"), Queue (target, @tg, bid, status; SELECT → accept /
  made / decline QR), job-done animation + LED when a Receipt lands. Register via QR.
- **Requester:** Find (introers on-chain, nearby badges first via mesh beacon of the introer's
  wallet), Bid (`ui.input` target and Telegram, amount; beat the lowest when 5 are open), My
  requests (confirm, withdraw, refund when expired). Each action → relay QR → phone signs.
- Poll the chain every 20 s within the 30 RPC calls/min budget.

## Trust model
No disputes and no arbiter. The introer is paid only when the requester confirms. If the
requester doesn't confirm within 72 hours of "intro made", anyone can refund them. The app
says so plainly: "We trust you to keep your word."
