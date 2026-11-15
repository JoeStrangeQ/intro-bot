# Intro Bot on !LAMPs

## Flow

1. **Request an intro.** Who, company, bid (10 to 500 !LAMPs) and your Telegram. The job goes
   on the public board right away, marked **Unpaid**.
2. **Fund (optional, any time).** The badge pays the bid into the app's escrow `ESC-GQD4T2WC`
   with `lamps.deposit` (memo `job <id>`); the OS asks you to approve. Once the server sees it
   in the escrow ledger, the job shows **Funded**. Funded jobs are listed first. An unpaid job
   nobody was picked for goes away after 72 hours.
3. **Offer.** Anyone can offer; no sign-up. The first offer makes your introer profile, named by your Telegram. Offering shows the
   requester's Telegram.
4. **Approve.** The requester picks one offer.
5. **We met.** Both open "We met" on the job and hold their badges close. The badges sign a
   mesh meet with `{job = id}`. The server reads the meets with the app's server key and
   marks the job **met** when the requester and the picked introer met.
6. **Made, confirm.** The introer can mark the intro made only after a verified meet. The
   requester confirms (any time after approving) and the server pays the bid from the
   escrow to the introer. An unpaid job must be funded first ("Pay the bid", then confirm).
7. **Edit and remove.** Edit who, company and Telegram any time before approving. Remove an unpaid job any time (nothing to give back), or remove a funded open one to get the bid back. To change the bid, remove and post again. Introers can withdraw an offer until they are picked.
8. **Refunds.** After approving: 7 days for made, then 72 hours to
   confirm; when a window passes the requester can refund. The server refunds by itself
   72 hours after that.

Max 3 live jobs per requester, 16 offers per job. A player can pay at most 500 !LAMPs a day
(badge rule).

## MAV

- **Machine value** (an introer's): earned x 0.8 x wear, wear = 1 - 1% per day
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
| `GET /board` | open jobs, funded first, then newest; 10. Rows carry `f` (funded) |
| `GET /me` | introer profile, machine value, my jobs, my offers |
| `GET /fleet` | `{paid, jobs}`: the Badge Fleet MAV |
| `GET /jobs/<id>` | one job, what I may do (`acts`), the offer pool for the requester |
| `POST /introer {name}` | rename (the first offer creates the introer) |
| `POST /jobs {who, co, tg, bid}` | new job: `{id, memo, esc}`; then deposit |
| `POST /jobs/<id>/<act>` | `paid`, `offer`, `withdraw`, `approve {n}`, `made`, `confirm`, `cancel` (bid back), `refund`, `edit {who, co, tg}`, `remove` (unpaid) |

State is one JSON file on a Railway volume (`DATA_DIR`).
