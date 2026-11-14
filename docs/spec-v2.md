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
