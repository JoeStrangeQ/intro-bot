# Intro Bot on !LAMPs

## Flow

1. **Request an intro.** Who, company, bid (10 to 500 !LAMPs) and your Telegram. The server
   makes the job; the badge pays the bid into the app's escrow `ESC-GQD4T2WC` with
   `lamps.deposit` (memo `job <id>`). The badge OS asks you to approve the payment.
2. **Board.** Once the server sees the deposit in the escrow ledger, the job is listed.
   Unpaid jobs go away after 30 minutes.
3. **Offer.** Registered introers offer (registering is free). Offering shows the
   requester's Telegram.
4. **Approve.** The requester picks one offer.
5. **We met.** Both open "We met" on the job and hold their badges close. The badges sign a
   mesh meet with `{job = id}`. The server reads the meets with the app's server key and
   marks the job **met** when the requester and the picked introer met.
6. **Made, confirm.** The introer can mark the intro made only after a verified meet. The
   requester confirms (any time after approving) and the server pays the bid from the
   escrow to the introer.
7. **Refunds.** Cancel while open. After approving: 7 days for made, then 72 hours to
   confirm; when a window passes the requester can refund. The server refunds by itself
   72 hours after that.

Max 3 live jobs per requester, 16 offers per job. A player can pay at most 500 !LAMPs a day
(badge rule).

## MAV

- **Machine value** (an introer's, "demo value"): earned x 0.8 x wear, wear = 1 - 1% per day
  (at least 0.5).
- **Badge Fleet MAV**: total !LAMPs paid to introers, and how many intros were paid.

## Trust

- The badge holds no keys. Every request carries the badge server's signed `X-Badge-*`
  headers; the server checks the signature, the app id, the time (1 minute) and replays.
- Only the server has the escrow key (payouts) and the app key (meets). They are Railway
  variables, never in the repo.
- Deposits that don't match a waiting job (wrong amount, wrong payer, unknown or paid job)
  are sent back. Every payout has a key, so a retry never pays twice.

## Server API

All under `https://relay.botbotcap.com/api`, signed by the badge server.

| Call | Does |
| --- | --- |
| `GET /board` | open jobs, newest 10 |
| `GET /me` | introer profile, machine value, my jobs, my offers |
| `GET /fleet` | `{paid, jobs}`: the Badge Fleet MAV |
| `GET /jobs/<id>` | one job, what I may do (`acts`), the offer pool for the requester |
| `POST /introer {name}` | register or rename |
| `POST /jobs {who, co, tg, bid}` | new job: `{id, memo, esc}`; then deposit |
| `POST /jobs/<id>/<act>` | `paid`, `offer`, `withdraw`, `approve {n}`, `made`, `confirm`, `cancel`, `refund` |

State is one JSON file on a Railway volume (`DATA_DIR`).
