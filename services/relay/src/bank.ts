// The badge server's escrow and meets API, with the keys only this server has.
import type { Bank, Deposit, Meet } from './api.ts';

type Raw = Record<string, unknown>;
const str = (v: unknown) => (v === undefined || v === null ? '' : String(v));

/** A ledger entry as a deposit, or null for anything else (payouts). Field names are read loosely. */
export function toDeposit(it: Raw): Deposit | null {
  const amount = Number(it.delta ?? it.amount); // the real ledger calls it delta
  const kind = str(it.type ?? it.kind ?? 'deposit');
  if (!(amount > 0) || !/deposit/i.test(kind)) return null;
  const from = (it.from ?? {}) as Raw;
  return {
    id: str(it.id),
    amount,
    memo: str(it.memo),
    user: str(it.user ?? it.userId ?? from.user),
    badge: str(it.badge ?? it.badgeId ?? from.badge),
  };
}

export function toMeet(it: Raw): Meet | null {
  const req = (it.req ?? {}) as Raw;
  const acc = (it.acc ?? {}) as Raw;
  const users: [string, string] = [str(req.user), str(acc.user)];
  if (!users[0] || !users[1]) return null;
  const jobs = [req.data, acc.data]
    .map((d) => str((d as Raw | undefined)?.job))
    .filter((j) => /^\d+$/.test(j));
  return { id: str(it.id), users, jobs: [...new Set(jobs)] };
}

export class BadgeBank implements Bank {
  private readonly base: string;
  private readonly escrowKey: string;
  private readonly appKey: string;

  constructor(base: string, escrowKey: string, appKey: string) {
    this.base = base;
    this.escrowKey = escrowKey;
    this.appKey = appKey;
  }

  private async get(path: string, key: string): Promise<Raw> {
    const r = await fetch(`${this.base}${path}`, { headers: { authorization: `Bearer ${key}` } });
    if (!r.ok) throw new Error(`${path}: ${r.status}`);
    return (await r.json()) as Raw;
  }

  async ledger(after: string) {
    const r = await this.get(`/api/escrow/ledger?after=${encodeURIComponent(after)}`, this.escrowKey);
    const raw = (r.items as Raw[]) ?? [];
    const last = raw.at(-1);
    return {
      items: raw.map(toDeposit).filter((d): d is Deposit => d !== null),
      next: last ? str(last.id) : after,
    };
  }

  async meets(after: string) {
    const r = await this.get(`/api/app/meets?after=${encodeURIComponent(after)}`, this.appKey);
    const raw = (r.items as Raw[]) ?? [];
    const last = raw.at(-1);
    return {
      items: raw.map(toMeet).filter((m): m is Meet => m !== null),
      next: last ? str(last.id) : after,
    };
  }

  async pay(to: string, amount: number, memo: string, key: string) {
    const r = await fetch(`${this.base}/api/escrow/pay`, {
      method: 'POST',
      headers: { authorization: `Bearer ${this.escrowKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ to, amount, memo, key }),
    });
    // 409: this key was paid already.
    if (!r.ok && r.status !== 409) throw new Error(`pay: ${r.status} ${await r.text()}`);
  }
}
