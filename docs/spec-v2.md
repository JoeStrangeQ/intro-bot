# Intro Bot v2: the intro board

v2 replaces the v1 flow (bids to a chosen introer). It's requester-first: you post a job, people
offer to make the intro, and you pick one. Where this file and `spec.md` disagree, this file wins.
Unchanged from v1: one top-level intro_escrow instruction per transaction, the relay, the 0x01
fee-payer placeholder, fixed-size layouts with fixed offsets, `confirmed` reads, no keys on the badge.

## Flow

1. **Request an intro.** It opens straight to this screen. The requester enters **who** (name),
   **company** and the **bid** in SOL, plus their Telegram. The badge shows the Solana Pay QR;
   the phone signs `post_job`, and the bid goes into the job's escrow.
2. **Board.** The job is listed on the public intro board: who, company and bid. The Telegram
   handle is hidden in the app.
3. **Offer.** Any registered introer can offer to make the intro (`offer`). There is no limit
   on offers. Offering reveals the requester's Telegram in the offerer's app, so they can talk.
4. **Approve.** After talking on Telegram, the requester picks one offer from the pool
   (`approve`). Other offers stay but can't be approved any more.
5. **Made → confirm.** The approved introer marks it made, then the requester confirms and the
   introer is paid. This is the receipt: introer `jobs_done` and `earned` rise.
6. **Refunds.** The requester can cancel any time before approving. After approving: 7 days
   for `mark_made`, then 72 hours to confirm. If either window passes, the requester can
   refund; anyone else can 72 hours after that (as in v1).

Telegram is stored on-chain and hidden only in the app. Anyone reading the chain can see it,
and the app says so on the request screen: "Your Telegram is shown to people who offer."

## Accounts (fixed layouts; document exact offsets)

- `Config` ["config"]: admin, pending_admin, paused, bump. `paused` blocks only `post_job` and `offer`.
- `Board` ["board"]: `head: u8`, `jobs: [Pubkey; 64]`, a ring of the newest job addresses,
  written by `post_job`. Created in `init_config`.
- `Introer` ["introer", wallet]: wallet, badge_id [u8;8], name [u8;32], jobs_done u32,
  earned u64, created_at, bump. Registered once (`register_introer`, `update_introer`).
- `Job` ["job", requester, nonce u64 le]: requester, nonce, bid, status (0 Open, 1 Approved,
  2 Made), created_at, approved_at, made_at, `approved: Pubkey` (introer wallet, default if none),
  `offer_count: u16`, `offers: [Pubkey; 16]` (ring of the newest offering introer wallets),
  `offers_head: u8`, then text: who [u8;32], company [u8;32], telegram [u8;32], bump.
  The bid lamports sit in the account on top of rent. It closes on settlement, and rent goes
  back to the requester. The client picks the nonce (e.g. a time value), so posts never collide.
- `Offer` ["offer", job, introer_wallet]: job, introer, created_at, bump. It proves the offer
  and stops duplicates. Its rent goes back to the introer: closed by the introer any time with
  `withdraw_offer` (not the approved one while the job is live), or by anyone once the job is closed.

## Instructions

| Ix | Signer | Rule |
| --- | --- | --- |
| `register_introer(badge_id, name)` / `update_introer` | wallet | profile |
| `post_job(nonce, who, company, telegram, bid)` | requester | not paused; 0.01 ≤ bid ≤ 100 SOL; who, company, telegram non-empty; adds to the Board ring |
| `cancel_job` | requester | Open → refund and close |
| `offer` | introer wallet | not paused; job Open; registered; not the requester; creates the Offer; pushes to `offers`; `offer_count += 1` |
| `withdraw_offer` | introer | closes their Offer (refused for the approved one while the job is live) |
| `close_offer` | anyone | Offer whose job account no longer exists → close, rent to the introer |
| `approve(introer_wallet)` | requester | Open, and an Offer exists for that introer → Approved, `approved_at` |
| `mark_made` | approved introer | Approved and now ≤ approved_at + 7d → Made |
| `confirm` | requester | Approved or Made → pay the approved introer's wallet; update Introer stats; close. Receipt. |
| `refund_expired` | requester after 7d of Approved; anyone after 7d + 72h | refund, close |
| `refund_unconfirmed` | requester after 72h of Made; anyone after 72h + 72h | refund, close |
| admin: `init_config`, `propose_admin`, `accept_admin`, `cancel_admin_proposal`, `set_paused` | admin | as v1 |

Events: JobPosted, JobCancelled, Offered, OfferWithdrawn, Approved, Made, Receipt, Refunded{reason}.
Remove from v1: `bid`, `withdraw`, `accept`, `decline`, the open-request queue, `Request`, `Directory`.

## Badge app

- **Home = Request an intro**: who → company → bid → Telegram (remembered) → QR. Then "Posted ✓".
- **Board**: newest jobs from the Board ring (getMultipleAccounts): who, company, bid, offers.
  SELECT → Offer (QR). After offering, show the requester's Telegram.
- **My jobs** (requester): status, offer pool (Introer names, jobs done, earned per offerer);
  SELECT an offerer → Approve QR; then Confirm / Cancel / Refund by state.
- **My offers** (introer): jobs I offered on; the approved one shows "Mark made" QR.
- **Profile**: register as an introer; machine value "demo value" ticker; "Ask me about BotBot · botbotcap.com".
- Keep: demo mode, retry if a tx fails, LED and animation on Receipt.

## Relay

Allowlist: register_introer, update_introer, post_job, cancel_job, offer, withdraw_offer,
close_offer, approve, mark_made, confirm, refund_expired, refund_unconfirmed. Refuse admin ones.

## Program details (filled in by the program branch)

Program id `GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC`. IDL: `idl/intro_escrow.json`.
Test vectors: `tests/fixtures/*.json` (one per instruction: accounts in order + data hex) and
`tests/fixtures/accounts.json` (raw account bytes). Both are rewritten by `cargo test`.

All accounts are fixed size. Text is UTF-8, zero-padded to 32 bytes, and must not be empty.
Integers are little-endian. Offsets include the 8-byte discriminator.

**Additions to the spec above** (for safety):
- `Board.posted` counts jobs ever posted; each job gets `serial = posted`. The Offer PDA is
  `["offer", job, serial u64 le, introer_wallet]` and stores `job_serial`. If a requester
  re-posts with the same nonce after the job closed (same address), old offers have other
  addresses, so they can't be approved; anyone can `close_offer` them.
- `cancel_job` only from 1 hour after `created_at` (`TooEarly` before). Without it, post +
  cancel could cheaply flush the 64-slot board. Remaining risk: someone willing to lock
  64 small bids for an hour can still push others off the board; admin `set_paused` is the
  backstop, and clients can also find jobs by other means.
- The offers ring holds each wallet once. `withdraw_offer` on a live job removes the wallet
  from the ring and lowers `offer_count`, so `offer_count` is the number of live offers.
- `approve` takes no args: it approves `offer.introer` of the Offer account passed.
- `Board` is zero-copy (it's too big for the stack), so it has 6 padding bytes before `posted`.
- Events: `close_offer` emits `OfferClosed{job, introer}`.
- `update_introer(badge_id, name)` takes both fields.
- `offer` needs the introer PDA; that's what "registered" means. `offer_count` saturates.
- Refund wait for anyone but the requester: `+ CONFIRM_WINDOW` (72 h) on top of the requester's.

`Config` ["config"], 74 bytes: admin @8, pending_admin @40 (zeros when none), paused u8 @72, bump @73.

`Board` ["board"], 2072 bytes: head u8 @8 (next slot), bump @9, padding @10..16, posted u64 @16,
jobs[i] @24 + 32·i (i = 0..63, zeros when empty; old entries may point at closed jobs).

`Introer` ["introer", wallet], 101 bytes: wallet @8, badge_id [8] @40, name [32] @48,
jobs_done u32 @80, earned u64 @84, created_at i64 @92, bump @100.

`Job` ["job", requester, nonce u64 le], 733 bytes:

| Offset | Field | Type |
| --- | --- | --- |
| 8 | requester | Pubkey |
| 40 | nonce | u64 |
| 48 | serial | u64 |
| 56 | bid | u64 |
| 64 | status | u8 (0 Open, 1 Approved, 2 Made) |
| 65 | created_at | i64 |
| 73 | approved_at | i64 |
| 81 | made_at | i64 |
| 89 | approved | Pubkey (introer wallet; zeros until approved) |
| 121 | offer_count | u16 |
| 123 | who | [u8; 32] |
| 155 | company | [u8; 32] |
| 187 | telegram | [u8; 32] |
| 219 | bump | u8 |
| 220 | offers_head | u8 (next ring slot) |
| 221 + 32·i | offers[i], i = 0..15 | Pubkey (ring, zeros when empty) |

The offers ring is last: a board listing can read bytes 0..220 with a data slice.

`Offer` ["offer", job, job_serial u64 le, introer_wallet], 89 bytes: job @8, introer (wallet) @40,
job_serial u64 @72, created_at i64 @80, bump @88.

Instruction args (Borsh after the 8-byte discriminator): `register_introer(badge_id [u8;8],
name [u8;32])`, `update_introer(badge_id [u8;8], name [u8;32])`, `post_job(nonce u64, who [u8;32],
company [u8;32], telegram [u8;32], bid u64)`, `propose_admin(Pubkey)`, `set_paused(bool)`. Others take no args.

Account order (s = signer, w = writable):

| Ix | Accounts |
| --- | --- |
| `init_config` | authority (s,w), config (w), board (w), program, program_data, system_program |
| `propose_admin` / `cancel_admin_proposal` / `set_paused` | admin (s), config (w) |
| `accept_admin` | pending_admin (s), config (w) |
| `register_introer` | wallet (s,w), introer (w), system_program |
| `update_introer` | wallet (s), introer (w) |
| `post_job` | requester (s,w), config, board (w), job (w), system_program |
| `cancel_job` | requester (s,w), job (w) |
| `offer` | wallet (s,w), config, introer, job (w), offer (w), system_program |
| `withdraw_offer` | wallet (s,w), offer (w), job (w, = offer.job) |
| `close_offer` | caller (s), offer (w), wallet (w, = offer.introer), job (= offer.job) |
| `approve` | requester (s), job (w), offer (the chosen one, on this post) |
| `mark_made` | wallet (s, = job.approved), job (w) |
| `confirm` | requester (s,w), job (w), introer (w, PDA of job.approved), wallet (w, = job.approved) |
| `refund_expired` / `refund_unconfirmed` | caller (s), job (w), requester (w) |

Events: `JobPosted{job, requester, bid}`, `JobCancelled{job}`, `Offered{job, introer}`,
`OfferWithdrawn{job, introer}`, `OfferClosed{job, introer}`, `Approved{job, introer}`,
`Made{job, made_at}`, `Receipt{job, introer, requester, bid, jobs_done, earned}`,
`Refunded{job, reason}` (0 cancelled, 1 expired, 2 unconfirmed), `IntroerRegistered`, and the
admin events. `introer` in events is the wallet.

Every instruction runs alone in a tx within the default 200k CU; tests fail above 100k.
