# Intro Bot on !LAMPs

## Flow

1. **Request an intro.** Who, company, bid (10 to 500 !LAMPs) and your Telegram. The bid
   prompt shows your balance and what's left of the badge's 500 a day; a bid you can't pay is
   refused before anything is posted.
2. **Pay.** Every bid is paid into escrow when posted. The badge pays the bid into the app's escrow `ESC-GQD4T2WC`
   with `lamps.deposit` (memo `job <id>`); the OS asks you to approve. The post waits off the
   board until the server sees the deposit in the escrow ledger, then it's listed. If the
   payment is refused, the badge removes the post. A post never paid is dropped after 30 minutes.
3. **Offer.** Anyone can offer; no sign-up. The first offer makes your introer profile, named by your Telegram. Offering shows the
   requester's Telegram.
4. **Approve.** The requester picks one offer.
5. **Pay in person** (full bid). The introer opens "Get paid in person" on the job (mesh on).
   The requester opens "Pay in person": the badge lists badges nearby (the picked introer's
   first), they pick one and confirm, and the badges sign a mesh meet `{job = id, pay = 1}`.
   The introer's badge signs only on Get paid, for that job. The requester's badge then
   calls `POST /jobs/<id>/inperson {badge}`; the server checks the badge is the picked
   introer's ("That's not <name>" otherwise) and pays the full bid at once. The meet upload
   later marks the job met, as a record.
6. **Pay over Telegram** (half). The requester confirms; the server pays half the bid (rounded
   down) to the introer and the rest back to the requester.
7. **Edit and remove.** Edit who, company and Telegram any time before approving. Remove an open job to get the bid back. **Raise the bid** any time before it closes: the badge pays the difference (memo `job <id> +<diff>`), and the server adds it once it lands; a wrong one is returned. Introers can withdraw an offer until they are picked.
8. **Refunds.** 7 days after approving with no payout, the requester can refund. The server
   refunds by itself 72 hours after that.

Max 3 live jobs per requester, 16 offers per job. A player can pay at most 500 !LAMPs a day
(badge rule; refunds don't count back). `GET /me` returns `dep_today`, what the user deposited today (UTC).

## MAV

- **Machine value** (an introer's): (earned + bonuses) x 0.8 x wear, wear = 1 - 1% per day
  (at least 0.5).
- **Badge Fleet MAV**: total !LAMPs introers produced (bids paid + bonuses), and how many
  intros were paid.

## Rewards

- On a payout the introer gets a bonus, 50 !LAMPs in person or 25 over Telegram, if this pair
  of people (either way round) was never rewarded before.
- `GET /me` lists `claim`: bonuses the badge may claim now, at most 2 a day (UTC day), and
  `csize`: each one's size. The badge calls `lamps.award(<size>, "intro <id>")`, then `POST /jobs/<id>/bonus
  {awarded, needsX}`. The server marks it claimed only when something was awarded, once.
- Nothing awarded (no X linked, or the app's daily cap): it stays pending; the badge tries
  again an hour later. The cap itself is set by the badge team.
- `lamps.award` runs on the badge, so a changed badge could claim without the server. The
  cap limits that; the server's counts only include bonuses reported.

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
| `GET /board` | open (paid) jobs, newest first; 10 |
| `GET /me` | introer profile, machine value, my jobs, my offers, `claim` and `csize` (bonuses to claim), `dep_today` |
| `GET /fleet` | `{paid, jobs, bonus, made}`: the Badge Fleet MAV is `made` = paid + bonus |
| `GET /jobs/<id>` | one job, what I may do (`acts`), the offer pool and the picked introer's badge (`pbadge`) for the requester |
| `POST /jobs/<id>/bonus {awarded, needsX}` | record a claimed bonus (once) |
| `POST /introer {name}` | rename (the first offer creates the introer) |
| `POST /jobs {who, co, tg, bid}` | new job: `{id, memo, esc}`; then deposit |
| `POST /jobs/<id>/<act>` | `paid`, `offer`, `withdraw`, `approve {n}`, `inperson {badge}` (full bid), `telegram` (half), `cancel` (bid back), `refund`, `edit {who, co, tg}`, `raise {bid}` (returns `raise {memo, diff}` to pay), `remove` (a post not paid yet) |

State is one JSON file on a Railway volume (`DATA_DIR`).
