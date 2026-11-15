// Intro Bot on !LAMPs (docs/spec-lamps.md). Requesters pay a bid into the app's escrow with
// lamps.deposit; this server holds the board, pays the introer on confirm, refunds otherwise.
// The badge never holds a key: payouts need the escrow key, which only this server has.

import type { Caller } from './verify.ts';

export const MIN_BID = 10;
export const MAX_BID = 500; // a player can pay at most 500 !LAMPs a day
export const MAX_OFFERS = 16;
export const MAX_OPEN = 3; // live jobs per requester
export const BOARD_SHOW = 10;
export const PAY_WAIT = 72 * 3_600_000; // an unpaid job stays up to 72 h
export const WORK = 7 * 86_400_000; // approved -> made
export const CONFIRM = 72 * 3_600_000; // made -> confirm
export const TEXT = 31;

export type Status = 'pending' | 'open' | 'approved' | 'made' | 'closed';
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
  deposit?: string;
  approved?: string;
  approvedAt?: number;
  madeAt?: number;
  offers: string[];
  met?: boolean;
  outcome?: 'paid' | 'refunded';
};
export type Introer = { user: string; badge: string; name: string; jobs: number; earned: number; created: number };
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
  paid: number; // Badge Fleet MAV: !LAMPs paid to introers
  paidJobs: number;
};

export type Deposit = { id: string; amount: number; memo: string; user: string; badge: string };
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
  };
}

function text(v: unknown, what: string): string {
  const s = typeof v === 'string' ? v.replace(/[^\x20-\x7e]/g, '').trim() : '';
  if (!s) throw new Err(400, `${what} is required`);
  return s.slice(0, TEXT);
}

/** Machine value, as on the badge: earned × 0.8 × wear */
export function machineValue(i: Introer, now: number): number {
  const days = Math.floor((now - i.created) / 86_400_000); // whole days, as on the badge before
  return Math.floor(i.earned * 0.8 * Math.max(0.5, 1 - 0.01 * days));
}

export class App {
  s: State;
  private readonly bank: Bank;
  private readonly now: () => number;
  private readonly save: () => void;

  constructor(s: State, bank: Bank, now: () => number = Date.now, save: () => void = () => {}) {
    this.s = s;
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
    return { jobs: this.jobs((j) => j.status === 'open', c.user, BOARD_SHOW) };
  }

  me(c: Caller) {
    const i = this.s.introers[c.user];
    return {
      reg: !!i,
      name: i?.name ?? '',
      jobs: i?.jobs ?? 0,
      earned: i?.earned ?? 0,
      value: i ? machineValue(i, this.now()) : 0,
      mine: this.jobs((j) => j.requester === c.user && j.status !== 'closed', c.user, 6),
      offers: this.jobs((j) => j.offers.includes(c.user) && j.status !== 'closed', c.user, 6),
    };
  }

  fleet() {
    return { paid: this.s.paid, jobs: this.s.paidJobs };
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
      if (j.status === 'pending') out.push('pay', 'edit', 'remove');
      if (j.status === 'open') out.push('edit', 'cancel');
      if (j.status === 'approved' || j.status === 'made') out.push('confirm');
      if (j.status === 'approved' && t > (j.approvedAt ?? 0) + WORK) out.push('refund');
      if (j.status === 'made' && t > (j.madeAt ?? 0) + CONFIRM) out.push('refund');
      if (j.status === 'approved' || j.status === 'made') out.push('meet');
    } else if (j.offers.includes(user)) {
      if (j.approved === user) {
        if (j.status === 'approved') out.push(j.met ? 'made' : 'meet');
        else if (j.status === 'made' && !j.met) out.push('meet');
      } else if (j.status === 'open') out.push('withdraw');
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
    body: { n?: unknown; name?: unknown; who?: unknown; co?: unknown; tg?: unknown },
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
    if (!this.acts(j, c.user).includes(act) || act === 'meet' || act === 'pay') throw new Err(409, `can not ${act} now`);
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
      // Unpaid: nothing to give back. A deposit that lands later is returned by sync().
      const gone = this.job(c, id);
      delete this.s.jobs[j.id];
      this.save();
      return { ...gone, st: 'closed' as const, acts: [] };
    } else if (act === 'withdraw') {
      j.offers = j.offers.filter((u) => u !== c.user);
    } else if (act === 'made') {
      if (this.now() > (j.approvedAt ?? 0) + WORK) throw new Err(409, 'too late: 7 days passed');
      j.status = 'made';
      j.madeAt = this.now();
    } else if (act === 'confirm') {
      const u = j.approved as string;
      const i = this.s.introers[u];
      if (i) {
        i.jobs += 1;
        i.earned += j.bid;
      }
      this.s.paid += j.bid;
      this.s.paidJobs += 1;
      this.close(j, 'paid', this.s.badges[u] ?? u, `Intro Bot: intro ${j.id} confirmed`);
    } else if (act === 'cancel' || act === 'refund') {
      this.close(j, 'refunded', j.rbadge || j.requester, `Intro Bot: job ${j.id} refunded`);
    }
    this.save();
    await this.flush();
    return this.job(c, id);
  }

  private close(j: Job, outcome: 'paid' | 'refunded', to: string, why: string) {
    j.status = 'closed';
    j.outcome = outcome;
    this.queue(`${outcome === 'paid' ? 'pay' : 'refund'}-${j.id}`, to, j.bid, why);
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
      const j = this.s.jobs[jobOf(d.memo) ?? ''];
      if (j && j.status === 'pending' && j.requester === d.user && d.amount === j.bid) {
        j.status = 'open';
        j.deposit = d.id;
      } else {
        // Unknown job, wrong payer or amount, or paid twice: give it back.
        this.queue(`back-${d.id}`, d.badge || d.user, d.amount, 'Intro Bot: deposit returned');
      }
    }
    this.s.ledgerAfter = next;
    this.save();
  }

  /** Meets between a requester and their approved introer with {job=id} mark the job met. */
  async syncMeets() {
    const { items, next } = await this.bank.meets(this.s.meetsAfter);
    for (const m of items) {
      for (const id of m.jobs) {
        const j = this.s.jobs[id];
        if (!j || !j.approved || (j.status !== 'approved' && j.status !== 'made')) continue;
        const pair = new Set(m.users);
        if (pair.has(j.requester) && pair.has(j.approved) && j.requester !== j.approved) j.met = true;
      }
    }
    this.s.meetsAfter = next;
    this.save();
  }

  /** Drops unpaid posts after 72 h; refunds stalled jobs 72 h after the requester could. */
  sweep() {
    const t = this.now();
    for (const j of Object.values(this.s.jobs)) {
      if (j.status === 'pending' && t > j.created + PAY_WAIT) delete this.s.jobs[j.id];
      else if (
        (j.status === 'approved' && t > (j.approvedAt ?? 0) + WORK + CONFIRM) ||
        (j.status === 'made' && t > (j.madeAt ?? 0) + CONFIRM + CONFIRM)
      ) {
        this.close(j, 'refunded', j.rbadge || j.requester, `Intro Bot: job ${j.id} refunded`);
      }
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

export function jobOf(m: string): string | null {
  const x = /^job (\d+)$/.exec(m.trim());
  return x ? (x[1] ?? null) : null;
}
