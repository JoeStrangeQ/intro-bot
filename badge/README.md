# Intro Bot badge app

Request an intro at Breakpoint. Say who you want to meet, their company and your bid in
!LAMPs. Introers offer. You talk on Telegram, pick one, meet badge to badge, and they are
paid only when you confirm.

Your job goes on the board at once, unpaid. Fund it any time (the bid waits in the app's !LAMP
escrow); funded jobs show first, and a job must be funded before you confirm. The badge holds no keys: the server at
relay.botbotcap.com keeps the board and pays out, and the badge server signs who is asking.

## Screens

LEFT / RIGHT moves between screens. CANCEL goes back, or home from a main screen.

- **Home** (opens here): BotBot and a big QR to x.com/botbotcap, so people can scan your badge and follow.
  SELECT enters the app; CANCEL here exits.

- **Intro board**: "+ Request an intro", then jobs, funded first ("Funded" or "Unpaid"). SELECT one to
  offer; after you offer you see the requester's Telegram.
- **Badge Fleet**: the "Badge Fleet MAV", every !LAMP introers produced (bids paid plus bonuses), and intros paid.
- **Request an intro**: who, company, bid, Telegram (remembered). It's posted, then the app
  asks if you want to fund it now; you can also do it later from My jobs.
- **My jobs**: your jobs. Approve an offer, cancel, "We met", confirm, or refund.
- **My offers**: jobs you offered on. When picked: "We met", then "Intro made".
- **Profile**: your Telegram and machine value. No sign-up: everyone can request and offer.

"We met": both badges open it on the job and the introer or requester presses SELECT. The
badges sign a mesh meet; the server marks the job met. When a job you made is confirmed,
the badge plays "JOB DONE!".

## Rewards

After a confirmed intro the introer's badge claims a 50 !LAMP bonus with `lamps.award`:
at most 100 a day, one per pair of people, only after a verified meet, and only with X
linked. If nothing is given (no X, or the app's cap), it tries again an hour later. The
cap is set by the badge team.

## Publish

Permissions: `lamps`, `mesh`, `http` (host `relay.botbotcap.com`), `led`.

## Tests

From the repo root: `bash badge-test/e2e.sh`. It runs two simulated badges against the real
server and a fake badge API. Needs Lua and Node 24+.
