# Intro Bot badge app

Request an intro at Breakpoint. Say who you want to meet, their company and your bid in
!LAMPs. Introers offer. You talk on Telegram and pick one. Pay them in person (your badges
meet: the full bid) or over Telegram (half, the rest back to you).

Every bid is paid into the app's !LAMP escrow when you post; the job goes on the board once
the payment lands. Raise the bid any time from the job. The badge holds no keys: the server at
relay.botbotcap.com keeps the board and pays out, and the badge server signs who is asking.

## Screens

LEFT / RIGHT moves between screens. CANCEL goes back, or home from a main screen.

- **Home** (opens here): BotBot and a big QR to x.com/botbotcap, so people can scan your badge and follow.
  SELECT enters the app; CANCEL here exits.

- **Intro board**: "+ Request an intro", then jobs. Every bid listed is held in escrow. SELECT one to
  offer; after you offer you see the requester's Telegram.
- **Badge Fleet**: the "Badge Fleet MAV", every !LAMP introers produced (bids paid plus bonuses), and intros paid.
- **Request an intro**: who, company, bid, Telegram (remembered). The bid prompt shows your
  balance and what's left of the badge's 500 a day. You pay the bid right away; if you say no,
  nothing is posted.
- **My jobs**: your jobs. Approve an offer, raise the bid, cancel, pay in person, pay over
  Telegram, or refund.
- **My offers**: jobs you offered on. When picked: "Get paid in person".
- **Profile**: your Telegram and machine value. No sign-up: everyone can request and offer.

Paying in person: the introer opens "Get paid in person" on the job. The requester opens
"Pay in person", picks the introer from the badges nearby and confirms. Both badges sign a
mesh meet and the server pays the full bid at once. The introer's badge plays "JOB DONE!".

## Rewards

After a paid intro the introer's badge claims a bonus with `lamps.award`: 50 in person, 25
over Telegram, at most two a day, one per pair of people, and only with X linked. If nothing is given (no X, or the app's cap), it tries again an hour later. The
cap is set by the badge team.

## Publish

Permissions: `lamps`, `mesh`, `http` (host `relay.botbotcap.com`), `led`.

## Tests

From the repo root: `bash badge-test/e2e.sh`. It runs two simulated badges against the real
server and a fake badge API. Needs Lua and Node 24+.
