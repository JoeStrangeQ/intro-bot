// Intro Bot on !LAMPs (docs/spec-lamps.md). Requesters pay a bid into the app's escrow with
// lamps.deposit; this server holds the board, pays the introer on confirm, refunds otherwise.
// The badge never holds a key: payouts need the escrow key, which only this server has.

import type { Caller } from './verify.ts';

export const MIN_BID = 10;
export const MAX_BID = 500; // a player can pay at most 500 !LAMPs a day
export const MAX_OFFERS = 16;
export const MAX_OPEN = 3; // live jobs per requester
export const BOARD_SHOW = 10;
export const BONUS = 50; // !LAMPs awarded to the introer per confirmed intro (lamps.award)
export const BONUS_DAY = 2; // bonuses per introer per UTC day: 100 !LAMPs
export const PAY_WAIT = 30 * 60_000; // a post must be paid within 30 min, or it is dropped
export const WORK = 7 * 86_400_000; // approved -> paid; after this the requester can refund
export const CONFIRM = 72 * 3_600_000; // then anyone's sweep refunds
export const TEXT = 31;

// 'pending': posted, waiting for its deposit. Private; it goes on the board as 'open' once paid.
export type Status = 'pending' | 'open' | 'approved' | 'closed';
export type Job = {
  id: string;
  requester: string;
  rbadge: string;
  who: string;
  co: string;
  tg: string;
  bid: number;
  status: Status;
  created: number;
  deposit?: string; // the ledger id of the bid; every listed job has one
  approved?: string;
  approvedAt?: number;
  offers: string[];
  met?: boolean;
  outcome?: 'paid' | 'half' | 'refunded'; // half: paid over Telegram
  raiseTo?: number; // a funded job's new bid, waiting for the difference to land
};
export type Introer = {
  user: string;
  badge: string;
  name: string;
  jobs: number;
  earned: number;
  created: number;
  bonus?: number; // !LAMPs awarded on top of bids
};
/** A reward the introer's badge claims with lamps.award. */
export type Bonus = { user: string; size: number; claimed: boolean; at?: number; amount?: number };
export type Payout = { to: string; amount: number; memo: string; done: boolean };
export type State = {
  seq: number;
  jobs: Record<string, Job>;
  introers: Record<string, Introer>;
  badges: Record<string, string>; // user -> latest badge id
  payouts: Record<string, Payout>; // idempotency key -> payout
  deposits: Record<string, true>; // ledger ids already handled
  ledgerAfter: string;
  meetsAfter: string;
  paid: number; // !LAMPs paid to introers
  paidJobs: number;
  bonuses: Record<string, Bonus>; // job id -> reward
  pairs: Record<string, string>; // the two users, sorted -> job id; one reward per pair, ever
  bonusPaid: number; // !LAMPs awarded; Badge Fleet MAV = paid + bonusPaid
  depDay: Record<string, { day: number; sum: number }>; // user -> !LAMPs deposited that UTC day
};

export type Deposit = { id: string; amount: number; memo: string; user: string; badge: string; at?: number };
export type Meet = { id: string; users: [string, string]; jobs: string[] };

/** The badge server's escrow and meets API (docs: Escrows, Meets). */
export interface Bank {
  ledger(after: string): Promise<{ items: Deposit[]; next: string }>;
  pay(to: string, amount: number, memo: string, key: string): Promise<void>;
  meets(after: string): Promise<{ items: Meet[]; next: string }>;
}

export class Err extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function emptyState(): State {
  return {
    seq: 0,
    jobs: {},
    introers: {},
    badges: {},
    payouts: {},
    deposits: {},
    ledgerAfter: '0',
    meetsAfter: '0',
    paid: 0,
    paidJobs: 0,
    bonuses: {},
    pairs: {},
    bonusPaid: 0,
    depDay: {},
  };
}

function text(v: unknown, what: string): string {
  const s = typeof v === 'string' ? v.replace(/[^\x20-\x7e]/g, '').trim() : '';
  if (!s) throw new Err(400, `${what} is required`);
  return s.slice(0, TEXT);
}

/** Machine value, as on the badge: (earned + bonuses) × 0.8 × wear */
export function machineValue(i: Introer, now: number): number {
  const days = Math.floor((now - i.created) / 86_400_000); // whole days, as on the badge before
  return Math.floor((i.earned + (i.bonus ?? 0)) * 0.8 * Math.max(0.5, 1 - 0.01 * days));
}

export class App {
  s: State;
  private readonly bank: Bank;
  private readonly now: () => number;
  private readonly save: () => void;

  constructor(s: State, bank: Bank, now: () => number = Date.now, save: () => void = () => {}) {
    this.s = s;
    // Every bid is paid. Jobs saved while unpaid posts were listed go back to waiting for
    // their deposit, with a fresh 30 min to pay.
    for (const j of Object.values(s.jobs)) {
      const old = j as unknown as { madeAt?: number; status: string };
      if (j.status !== 'closed' && !j.deposit) {
        j.status = 'pending';
        j.created = now();
        delete j.approved;
        delete j.approvedAt;
        j.offers = [];
      }
      // "Intro made" is gone: a made job waits for its payout like an approved one.
      if (old.status === 'made') j.status = 'approved';
      delete old.madeAt;
    }
    for (const b of Object.values(s.bonuses ?? {})) b.size ??= BONUS;
    s.bonuses ??= {};
    s.pairs ??= {};
    s.bonusPaid ??= 0;
    s.depDay ??= {};
    this.bank = bank;
    this.now = now;
    this.save = save;
  }

  // Reads -------------------------------------------------------------------

  private row(j: Job, user: string) {
    return {
      id: j.id,
      who: j.who,
      co: j.co,
      bid: j.bid,
      n: j.offers.length,
      st: j.status,
      f: !!j.deposit,
      o: j.offers.includes(user),
      me: j.approved === user,
      met: !!j.met,
    };
  }

  private jobs(pred: (j: Job) => boolean, user: string, max: number) {
    return Object.values(this.s.jobs)
      .filter(pred)
      .sort((a, b) => b.created - a.created)
      .slice(0, max)
      .map((j) => this.row(j, user));
  }

  board(c: Caller) {
    // Only paid jobs are listed: every bid on the board is held in the escrow.
    return { jobs: this.jobs((j) => j.status === 'open', c.user, BOARD_SHOW) };
  }

  me(c: Caller) {
    const i = this.s.introers[c.user];
    return {
      reg: !!i,
      name: i?.name ?? '',
      jobs: i?.jobs ?? 0,
      earned: i?.earned ?? 0,
      bonus: i?.bonus ?? 0,
      value: i ? machineValue(i, this.now()) : 0,
      mine: this.jobs((j) => j.requester === c.user && j.status !== 'closed', c.user, 6),
      offers: this.jobs((j) => j.offers.includes(c.user) && j.status !== 'closed', c.user, 6),
      claim: this.claimable(c.user),
      csize: this.claimSizes(c.user),
      dep_today: this.depToday(c.user),
    };
  }

  /** !LAMPs this user deposited today (UTC). The badge allows 500 a day; refunds don't count back. */
  private depToday(user: string): number {
    const d = this.s.depDay[user];
    return d && d.day === Math.floor(this.now() / 86_400_000) ? d.sum : 0;
  }

  /** Bonuses this user's badge may claim now: unclaimed, within today's limit. */
  private claimable(user: string): string[] {
    const left = BONUS_DAY - this.claimedToday(user);
    if (left <= 0) return [];
    return Object.entries(this.s.bonuses)
      .filter(([, b]) => b.user === user && !b.claimed)
      .map(([id]) => id)
      .slice(0, left);
  }

  /** Job id -> bonus size (50 in person, 25 over Telegram) for what the badge may claim. */
  private claimSizes(user: string): Record<string, number> {
    const out: Record<string, number> = {};
    for (const id of this.claimable(user)) out[id] = this.s.bonuses[id]?.size ?? BONUS;
    return out;
  }

  private claimedToday(user: string): number {
    const day = Math.floor(this.now() / 86_400_000);
    return Object.values(this.s.bonuses).filter(
      (b) => b.user === user && b.claimed && Math.floor((b.at ?? 0) / 86_400_000) === day,
    ).length;
  }

  fleet() {
    return { paid: this.s.paid, jobs: this.s.paidJobs, bonus: this.s.bonusPaid, made: this.s.paid + this.s.bonusPaid };
  }

  private get(id: string): Job {
    const j = this.s.jobs[id];
    if (!j) throw new Err(404, 'no such job');
    return j;
  }

  /** What `user` may do on `j` now. */
  acts(j: Job, user: string): string[] {
    const t = this.now();
    const out: string[] = [];
    if (j.requester === user) {
      // A post waits for its deposit; retry paying it or remove it.
      if (j.status === 'pending') out.push('pay', 'remove');
      if (j.status === 'open') out.push('edit', 'cancel');
      // Picked: pay in person (mesh meet, full bid) or over Telegram (half).
      if (j.status === 'approved') out.push('inperson', 'telegram');
      if (j.status === 'approved' && t > (j.approvedAt ?? 0) + WORK) out.push('refund');
      if (j.status === 'open' || j.status === 'approved') out.push('raise');
    } else if (j.offers.includes(user)) {
      // The picked introer just stands nearby with the app open; the requester pays.
      if (j.status === 'open' && j.approved !== user) out.push('withdraw');
    } else if (j.status === 'open') out.push('offer');
    return out;
  }

  job(c: Caller, id: string) {
    const j = this.get(id);
    const mine = j.requester === c.user;
    const offered = j.offers.includes(c.user);
    return {
      ...this.row(j, c.user),
      tg: offered ? j.tg : undefined,
      mine,
      picked: j.approved ? (this.s.introers[j.approved]?.name ?? 'introer') : undefined,
      // The picked introer's badge, so the requester's badge can find it nearby.
      pbadge: mine && j.approved ? this.s.badges[j.approved] : undefined,
      pool: mine
        ? j.offers.map((u) => {
            const i = this.s.introers[u];
            return { name: i?.name ?? 'introer', jobs: i?.jobs ?? 0, earned: i?.earned ?? 0 };
          })
        : undefined,
      acts: this.acts(j, c.user),
    };
  }

  // Writes ------------------------------------------------------------------

  private seen(c: Caller) {
    if (c.badge && this.s.badges[c.user] !== c.badge) this.s.badges[c.user] = c.badge;
  }

  register(c: Caller, body: { name?: unknown }) {
    this.seen(c);
    const name = text(body.name, 'name');
    const i = this.s.introers[c.user];
    if (i) i.name = name;
    else this.s.introers[c.user] = { user: c.user, badge: c.badge, name, jobs: 0, earned: 0, created: this.now() };
    this.save();
    return this.me(c);
  }

  post(c: Caller, body: { who?: unknown; co?: unknown; tg?: unknown; bid?: unknown }) {
    this.seen(c);
    const bid = Number(body.bid);
    if (!Number.isInteger(bid) || bid < MIN_BID || bid > MAX_BID) {
      throw new Err(400, `bid must be ${MIN_BID} to ${MAX_BID} !LAMPs`);
    }
    const live = Object.values(this.s.jobs).filter(
      (j) => j.requester === c.user && j.status !== 'closed',
    ).length;
    if (live >= MAX_OPEN) throw new Err(409, `at most ${MAX_OPEN} jobs at a time`);
    let tg = text(body.tg, 'telegram');
    if (!tg.startsWith('@')) tg = `@${tg}`;
    const id = String(++this.s.seq);
    this.s.jobs[id] = {
      id,
      requester: c.user,
      rbadge: c.badge,
      who: text(body.who, 'who'),
      co: text(body.co, 'company'),
      tg: tg.slice(0, TEXT),
      bid,
      status: 'pending',
      created: this.now(),
      offers: [],
    };
    this.save();
    return { id, memo: memo(id), bid };
  }

  async act(
    c: Caller,
    id: string,
    act: string,
    body: { n?: unknown; name?: unknown; who?: unknown; co?: unknown; tg?: unknown; bid?: unknown; badge?: unknown },
  ) {
    this.seen(c);
    const j = this.get(id);
    if (act === 'paid') {
      if (j.requester !== c.user) throw new Err(403, 'not your job');
      await this.sync();
      return this.job(c, id);
    }
    if (act === 'approve') {
      if (j.requester !== c.user || j.status !== 'open') throw new Err(409, 'can not approve now');
      const u = j.offers[Number(body.n)];
      if (!u) throw new Err(400, 'no such offer');
      j.status = 'approved';
      j.approved = u;
      j.approvedAt = this.now();
      this.save();
      return this.job(c, id);
    }
    if (!this.acts(j, c.user).includes(act) || act === 'pay') throw new Err(409, `can not ${act} now`);
    if (act === 'offer') {
      if (j.offers.length >= MAX_OFFERS) throw new Err(409, 'this job is full');
      j.offers.push(c.user);
      // Everyone is an introer: the first offer makes the profile, named by Telegram.
      if (!this.s.introers[c.user]) {
        const name = typeof body.name === 'string' && body.name.trim() ? text(body.name, 'name') : 'introer';
        this.s.introers[c.user] = { user: c.user, badge: c.badge, name, jobs: 0, earned: 0, created: this.now() };
      }
    } else if (act === 'edit') {
      if (body.who !== undefined) j.who = text(body.who, 'who');
      if (body.co !== undefined) j.co = text(body.co, 'company');
      if (body.tg !== undefined) {
        let tg = text(body.tg, 'telegram');
        if (!tg.startsWith('@')) tg = `@${tg}`;
        j.tg = tg.slice(0, TEXT);
      }
    } else if (act === 'remove') {
      // Not paid yet: nothing to give back. A deposit that lands later is returned by sync().
      const gone = this.job(c, id);
      delete this.s.jobs[j.id];
      this.save();
      return { ...gone, st: 'closed' as const, acts: [] };
    } else if (act === 'raise') {
      const bid = Number(body.bid);
      if (!Number.isInteger(bid) || bid <= j.bid || bid > MAX_BID) {
        throw new Err(400, `new bid must be more than ${j.bid}, up to ${MAX_BID} !LAMPs`);
      }
      // The badge pays the difference; sync() adds it once it lands.
      j.raiseTo = bid;
      this.save();
      return { ...this.job(c, id), raise: { memo: raiseMemo(id, bid - j.bid), diff: bid - j.bid } };
    } else if (act === 'withdraw') {
      j.offers = j.offers.filter((u) => u !== c.user);
    } else if (act === 'inperson') {
      // Both badges signed a meet just now; the request itself is signed by the requester.
      const u = j.approved as string;
      if (String(body.badge ?? '') !== this.s.badges[u]) {
        throw new Err(409, `That's not ${this.s.introers[u]?.name ?? 'your introer'}`);
      }
      j.met = true;
      this.payIntro(j, j.bid, BONUS);
    } else if (act === 'telegram') {
      this.payIntro(j, Math.floor(j.bid / 2), BONUS / 2);
    } else if (act === 'cancel' || act === 'refund') {
      this.close(j, 'refunded', j.rbadge || j.requester, `Intro Bot: job ${j.id} refunded`);
    }
    this.save();
    await this.flush();
    return this.job(c, id);
  }

  /** The introer's badge reports what lamps.award gave for job `id`'s bonus. */
  bonus(c: Caller, id: string, body: { awarded?: unknown; needsX?: unknown }) {
    this.seen(c);
    const b = this.s.bonuses[id];
    if (!b || b.user !== c.user) throw new Err(404, 'no bonus for this job');
    if (b.claimed) return { claimed: true, amount: b.amount ?? 0, claim: this.claimable(c.user), csize: this.claimSizes(c.user) };
    const got = Number(body.awarded);
    if (Number.isInteger(got) && got > 0) {
      if (this.claimedToday(c.user) >= BONUS_DAY) throw new Err(409, 'bonus limit for today');
      const amount = Math.min(got, b.size);
      b.claimed = true;
      b.at = this.now();
      b.amount = amount;
      const i = this.s.introers[c.user];
      if (i) i.bonus = (i.bonus ?? 0) + amount;
      this.s.bonusPaid += amount;
      this.save();
    }
    // Nothing awarded (no X linked, or the app's daily cap): it stays to claim later.
    return { claimed: b.claimed, amount: b.amount ?? 0, claim: this.claimable(c.user), csize: this.claimSizes(c.user) };
  }

  /** Pays `amount` of the bid to the picked introer, the rest back to the requester. */
  private payIntro(j: Job, amount: number, bonus: number) {
    const u = j.approved as string;
    const i = this.s.introers[u];
    if (i) {
      i.jobs += 1;
      i.earned += amount;
    }
    this.s.paid += amount;
    this.s.paidJobs += 1;
    // Reward: a pair never rewarded before, either way round.
    const pair = [j.requester, u].sort().join('|');
    if (!this.s.pairs[pair]) {
      this.s.pairs[pair] = j.id;
      this.s.bonuses[j.id] = { user: u, size: bonus, claimed: false };
    }
    j.status = 'closed';
    j.outcome = amount === j.bid ? 'paid' : 'half';
    this.queue(`pay-${j.id}`, this.s.badges[u] ?? u, amount, `Intro Bot: intro ${j.id} paid`);
    if (amount < j.bid) {
      this.queue(`refund-${j.id}`, j.rbadge || j.requester, j.bid - amount, `Intro Bot: job ${j.id} half back`);
    }
  }

  private close(j: Job, outcome: 'refunded', to: string, why: string) {
    j.status = 'closed';
    j.outcome = outcome;
    this.queue(`refund-${j.id}`, to, j.bid, why);
  }

  private queue(key: string, to: string, amount: number, memo_: string) {
    if (!this.s.payouts[key]) this.s.payouts[key] = { to, amount, memo: memo_.slice(0, 64), done: false };
  }

  // Background ----------------------------------------------------------------

  /** Sends payouts not yet confirmed. The key makes each safe to retry. */
  async flush() {
    for (const [key, p] of Object.entries(this.s.payouts)) {
      if (p.done) continue;
      try {
        await this.bank.pay(p.to, p.amount, p.memo, key);
        p.done = true;
        this.save();
      } catch {
        // retried on the next tick
      }
    }
  }

  /** New deposits: fund the job they name, or send them back. */
  async sync() {
    const { items, next } = await this.bank.ledger(this.s.ledgerAfter);
    for (const d of items) {
      if (this.s.deposits[d.id]) continue;
      this.s.deposits[d.id] = true;
      this.countDeposit(d);
      const r = raiseOf(d.memo);
      const j = this.s.jobs[r?.id ?? jobOf(d.memo) ?? ''];
      const live = j && (j.status === 'open' || j.status === 'approved');
      if (r && j && live && j.deposit && j.raiseTo && j.requester === d.user &&
          d.amount === r.diff && j.bid + r.diff === j.raiseTo) {
        j.bid = j.raiseTo; // the raise landed
        delete j.raiseTo;
      } else if (!r && j && j.status === 'pending' && j.requester === d.user && d.amount === j.bid) {
        j.deposit = d.id;
        j.status = 'open'; // paid: on the board now
      } else {
        // Unknown job, wrong payer or amount, or paid twice: give it back.
        this.queue(`back-${d.id}`, d.badge || d.user, d.amount, 'Intro Bot: deposit returned');
      }
    }
    this.s.ledgerAfter = next;
    this.save();
  }

  private countDeposit(d: Deposit) {
    const day = Math.floor((d.at ?? this.now()) / 86_400_000);
    const cur = this.s.depDay[d.user];
    this.s.depDay[d.user] = cur && cur.day === day ? { day, sum: cur.sum + d.amount } : { day, sum: d.amount };
  }

  /** Meets between a requester and their picked introer with {job=id} mark the job met (a record). */
  async syncMeets() {
    const { items, next } = await this.bank.meets(this.s.meetsAfter);
    for (const m of items) {
      for (const id of m.jobs) {
        const j = this.s.jobs[id];
        if (!j || !j.approved) continue;
        const pair = new Set(m.users);
        if (pair.has(j.requester) && pair.has(j.approved) && j.requester !== j.approved) j.met = true;
      }
    }
    this.s.meetsAfter = next;
    this.save();
  }

  /** Drops posts never paid after 30 min; refunds stalled jobs 72 h after the requester could. */
  sweep() {
    const t = this.now();
    for (const j of Object.values(this.s.jobs)) {
      const stalled = j.status === 'approved' && t > (j.approvedAt ?? 0) + WORK + CONFIRM;
      if (j.status === 'pending' && t > j.created + PAY_WAIT) delete this.s.jobs[j.id];
      else if (stalled) this.close(j, 'refunded', j.rbadge || j.requester, `Intro Bot: job ${j.id} refunded`);
    }
    // Closed jobs are kept 30 days, then dropped.
    for (const j of Object.values(this.s.jobs)) {
      if (j.status === 'closed' && t > j.created + 30 * 86_400_000) delete this.s.jobs[j.id];
    }
    this.save();
  }

  async tick() {
    for (const f of [() => this.sync(), () => this.syncMeets(), async () => this.sweep(), () => this.flush()]) {
      try {
        await f();
      } catch (e) {
        console.error('tick', (e as Error).message);
      }
    }
  }
}

export function memo(id: string) {
  return `job ${id}`;
}

export function raiseMemo(id: string, diff: number) {
  return `job ${id} +${diff}`;
}

/** "job 7 +40" -> {id: "7", diff: 40}: a raise on a funded job. */
export function raiseOf(m: string): { id: string; diff: number } | null {
  const x = /^job (\d+) \+(\d+)$/.exec(m.trim());
  return x ? { id: x[1] ?? '', diff: Number(x[2]) } : null;
}

export function jobOf(m: string): string | null {
  const x = /^job (\d+)$/.exec(m.trim());
  return x ? (x[1] ?? null) : null;
}
