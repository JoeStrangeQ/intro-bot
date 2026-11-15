import { describe, expect, it } from 'vitest';
import { App, CONFIRM, emptyState, PAY_WAIT, WORK, type Bank, type Deposit, type Meet } from '../src/api.ts';
import { toDeposit, toMeet } from '../src/bank.ts';
import { route } from '../src/server.ts';
import { Verifier } from '../src/verify.ts';

class FakeBank implements Bank {
  ledgerItems: Deposit[] = [];
  meetItems: Meet[] = [];
  paid = new Map<string, { to: string; amount: number }>();
  calls = 0;
  failPay = false;
  async ledger(after: string) {
    const items = this.ledgerItems.filter((d) => Number(d.id) > Number(after));
    return { items, next: items.at(-1)?.id ?? after };
  }
  async meets(after: string) {
    const items = this.meetItems.filter((m) => Number(m.id) > Number(after));
    return { items, next: items.at(-1)?.id ?? after };
  }
  async pay(to: string, amount: number, _memo: string, key: string) {
    this.calls++;
    if (this.failPay) throw new Error('down');
    if (!this.paid.has(key)) this.paid.set(key, { to, amount });
  }
  deposit(user: string, badge: string, amount: number, memo: string) {
    this.ledgerItems.push({ id: String(this.ledgerItems.length + 1), user, badge, amount, memo });
  }
}

const REQ = { user: 'u-req', badge: 'BREQ01' };
const INT = { user: 'u-int', badge: 'BINT01' };
const OTHER = { user: 'u-oth', badge: 'BOTH01' };

function setup() {
  let t = 1_790_000_000_000;
  const bank = new FakeBank();
  const app = new App(emptyState(), bank, () => t);
  return { app, bank, at: (ms: number) => (t += ms) };
}

async function openJob(s: ReturnType<typeof setup>, bid = 50) {
  const { id } = s.app.post(REQ, { who: 'Toly', co: 'Solana', tg: 'req', bid });
  s.bank.deposit(REQ.user, REQ.badge, bid, `job ${id}`);
  await s.app.act(REQ, id, 'paid', {});
  return id;
}

describe('posting and deposits', () => {
  it('lists a job only after its deposit is in the ledger', async () => {
    const s = setup();
    const { id, memo } = s.app.post(REQ, { who: 'Toly', co: 'Solana', tg: 'req', bid: 50 });
    expect(memo).toBe(`job ${id}`);
    expect(s.app.board(OTHER).jobs).toHaveLength(0);
    s.bank.deposit(REQ.user, REQ.badge, 50, memo);
    await s.app.sync();
    expect(s.app.board(OTHER).jobs.map((j) => j.id)).toEqual([id]);
    expect(s.app.s.jobs[id]?.tg).toBe('@req');
  });

  it('returns deposits from the wrong payer, wrong amount, unknown job or twice', async () => {
    const s = setup();
    const { id } = s.app.post(REQ, { who: 'A', co: 'B', tg: '@x', bid: 50 });
    s.bank.deposit(OTHER.user, OTHER.badge, 50, `job ${id}`); // wrong payer
    s.bank.deposit(REQ.user, REQ.badge, 40, `job ${id}`); // wrong amount
    s.bank.deposit(REQ.user, REQ.badge, 30, 'job 999'); // no such job
    s.bank.deposit(REQ.user, REQ.badge, 50, `job ${id}`); // the right one
    s.bank.deposit(REQ.user, REQ.badge, 50, `job ${id}`); // twice
    await s.app.sync();
    await s.app.flush();
    expect(s.app.s.jobs[id]?.status).toBe('open');
    expect([...s.bank.paid.values()]).toEqual([
      { to: OTHER.badge, amount: 50 },
      { to: REQ.badge, amount: 40 },
      { to: REQ.badge, amount: 30 },
      { to: REQ.badge, amount: 50 },
    ]);
    // A second sync sees nothing new.
    await s.app.sync();
    await s.app.flush();
    expect(s.bank.paid.size).toBe(4);
  });

  it('checks bids and text', () => {
    const s = setup();
    expect(() => s.app.post(REQ, { who: 'A', co: 'B', tg: 'x', bid: 9 })).toThrow(/10 to 500/);
    expect(() => s.app.post(REQ, { who: 'A', co: 'B', tg: 'x', bid: 501 })).toThrow(/10 to 500/);
    expect(() => s.app.post(REQ, { who: 'A', co: 'B', tg: 'x', bid: 10.5 })).toThrow();
    expect(() => s.app.post(REQ, { who: ' ', co: 'B', tg: 'x', bid: 10 })).toThrow(/who/);
  });

  it('drops unpaid posts after 30 minutes', () => {
    const s = setup();
    const { id } = s.app.post(REQ, { who: 'A', co: 'B', tg: 'x', bid: 10 });
    s.at(PAY_WAIT + 1);
    s.app.sweep();
    expect(s.app.s.jobs[id]).toBeUndefined();
  });

  it('allows three live jobs per requester', () => {
    const s = setup();
    for (let k = 0; k < 3; k++) s.app.post(REQ, { who: 'A', co: 'B', tg: 'x', bid: 10 });
    expect(() => s.app.post(REQ, { who: 'A', co: 'B', tg: 'x', bid: 10 })).toThrow(/at most 3/);
  });
});

describe('the intro flow', () => {
  it('offer, approve, meet, made, confirm pays the introer and the Fleet MAV', async () => {
    const s = setup();
    const id = await openJob(s, 100);
    expect(s.app.job(INT, id).tg).toBeUndefined();
    expect(s.app.me(INT).reg).toBe(false);
    await s.app.act(INT, id, 'offer', { name: 'Ana' }); // no sign-up: the first offer makes the introer
    expect(s.app.me(INT).name).toBe('Ana');
    expect(s.app.job(INT, id).tg).toBe('@req');
    expect(s.app.job(REQ, id).pool).toEqual([{ name: 'Ana', jobs: 0, earned: 0 }]);
    await expect(s.app.act(OTHER, id, 'approve', { n: 0 })).rejects.toThrow();
    await s.app.act(REQ, id, 'approve', { n: 0 });
    // Made needs a verified meet first.
    expect(s.app.job(INT, id).acts).toEqual(['meet']);
    await expect(s.app.act(INT, id, 'made', {})).rejects.toThrow();
    s.bank.meetItems.push({ id: '1', users: [OTHER.user, INT.user], jobs: [id] }); // wrong pair
    await s.app.syncMeets();
    expect(s.app.s.jobs[id]?.met).toBeFalsy();
    s.bank.meetItems.push({ id: '2', users: [INT.user, REQ.user], jobs: [id] });
    await s.app.syncMeets();
    expect(s.app.job(INT, id).met).toBe(true);
    await s.app.act(INT, id, 'made', {});
    const out = await s.app.act(REQ, id, 'confirm', {});
    expect(out.st).toBe('closed');
    expect(s.bank.paid.get(`pay-${id}`)).toEqual({ to: INT.badge, amount: 100 });
    expect(s.app.fleet()).toEqual({ paid: 100, jobs: 1 });
    expect(s.app.me(INT)).toMatchObject({ jobs: 1, earned: 100, value: 80 });
  });

  it('requester can confirm before made', async () => {
    const s = setup();
    const id = await openJob(s);
    await s.app.act(INT, id, 'offer', { name: 'Ana' });
    await s.app.act(REQ, id, 'approve', { n: 0 });
    await s.app.act(REQ, id, 'confirm', {});
    expect(s.app.fleet().jobs).toBe(1);
  });

  it('cancel refunds an open job; withdraw removes an offer', async () => {
    const s = setup();
    const id = await openJob(s, 20);
    await s.app.act(INT, id, 'offer', { name: 'Ana' });
    await s.app.act(INT, id, 'withdraw', {});
    expect(s.app.s.jobs[id]?.offers).toEqual([]);
    await expect(s.app.act(INT, id, 'cancel', {})).rejects.toThrow();
    await s.app.act(REQ, id, 'cancel', {});
    expect(s.bank.paid.get(`refund-${id}`)).toEqual({ to: REQ.badge, amount: 20 });
  });

  it('requester can edit a job, and remove it before paying', async () => {
    const s = setup();
    const id = await openJob(s, 20);
    await s.app.act(REQ, id, 'edit', { who: 'Mert', co: 'Helius', tg: 'new' });
    expect(s.app.s.jobs[id]).toMatchObject({ who: 'Mert', co: 'Helius', tg: '@new' });
    await expect(s.app.act(INT, id, 'edit', { who: 'x' })).rejects.toThrow();
    const { id: un } = s.app.post(REQ, { who: 'A', co: 'B', tg: 'req', bid: 30 });
    expect(s.app.acts(s.app.s.jobs[un]!, REQ.user)).toEqual(['pay', 'edit', 'remove']);
    await s.app.act(REQ, un, 'remove', {});
    expect(s.app.s.jobs[un]).toBeUndefined();
    s.bank.deposit(REQ.user, REQ.badge, 30, `job ${un}`); // paid late: given back
    await s.app.sync();
    await s.app.flush();
    expect([...s.bank.paid.values()]).toContainEqual({ to: REQ.badge, amount: 30 });
  });

  it('refund opens after 7 days approved, and auto-refunds 72 h later', async () => {
    const s = setup();
    const id = await openJob(s);
    await s.app.act(INT, id, 'offer', { name: 'Ana' });
    await s.app.act(REQ, id, 'approve', { n: 0 });
    await expect(s.app.act(REQ, id, 'refund', {})).rejects.toThrow();
    s.at(WORK + 1);
    expect(s.app.job(REQ, id).acts).toContain('refund');
    s.at(CONFIRM);
    s.app.sweep();
    await s.app.flush();
    expect(s.app.s.jobs[id]?.status).toBe('closed');
    expect(s.bank.paid.has(`refund-${id}`)).toBe(true);
  });

  it('retries a failed payout once with the same key', async () => {
    const s = setup();
    const id = await openJob(s);
    s.bank.failPay = true;
    await s.app.act(REQ, id, 'cancel', {});
    expect(s.app.s.payouts[`refund-${id}`]?.done).toBe(false);
    s.bank.failPay = false;
    await s.app.flush();
    await s.app.flush();
    expect(s.app.s.payouts[`refund-${id}`]?.done).toBe(true);
    expect(s.bank.paid.size).toBe(1);
    // Cancel again is refused: no double refund.
    await expect(s.app.act(REQ, id, 'cancel', {})).rejects.toThrow();
  });
});

describe('routes', () => {
  it('maps paths to the app', async () => {
    const s = setup();
    const r = (await route(s.app, 'POST', '/api/jobs', REQ, { who: 'A', co: 'B', tg: 'x', bid: 10 })) as {
      esc: string;
    };
    expect(r.esc).toBe('ESC-GQD4T2WC');
    expect(await route(s.app, 'GET', '/api/fleet', REQ, {})).toEqual({ paid: 0, jobs: 0 });
    await expect(route(s.app, 'GET', '/api/nope', REQ, {})).rejects.toThrow(/not found/);
  });
});

describe('ledger and meets parsing', () => {
  it('reads deposits and skips payouts', () => {
    expect(toDeposit({ id: 7, amount: 50, memo: 'job 1', user: 'u', badge: 'B' })).toEqual({
      id: '7',
      amount: 50,
      memo: 'job 1',
      user: 'u',
      badge: 'B',
    });
    expect(toDeposit({ id: 8, amount: -50, memo: 'x' })).toBeNull();
    // The real ledger's shape (seen live): kind + delta.
    expect(
      toDeposit({ id: '165', kind: 'deposit', delta: 90, balance: 100, user: 'u', badge: '7ZNCET', app: 'intro-bot', memo: 'job 5' }),
    ).toEqual({ id: '165', amount: 90, memo: 'job 5', user: 'u', badge: '7ZNCET' });
    expect(toDeposit({ id: 9, amount: 50, type: 'payout' })).toBeNull();
  });
  it('reads meets', () => {
    expect(
      toMeet({ id: 1, req: { user: 'a', data: { job: '5' } }, acc: { user: 'b', data: { job: '5' } } }),
    ).toEqual({ id: '1', users: ['a', 'b'], jobs: ['5'] });
    expect(toMeet({ id: 2, req: { user: null }, acc: { user: 'b' } })).toBeNull();
  });
});

describe('signed headers', () => {
  async function signer() {
    const kp = (await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])) as CryptoKeyPair;
    const raw = Buffer.from(await crypto.subtle.exportKey('raw', kp.publicKey)).toString('base64');
    const url = `data:application/json,${encodeURIComponent(JSON.stringify({ id: 'k1', key: raw }))}`;
    const sign = async (method: string, u: string, body: string, time: number, id: string, app = 'intro-bot') => {
      const hash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body))).toString('hex');
      const msg = ['badge-http-v1', method, u, hash, app, 'B1', 'u1', String(time), id].join('\n');
      const sig = Buffer.from(await crypto.subtle.sign('Ed25519', kp.privateKey, new TextEncoder().encode(msg)));
      const h: Record<string, string> = {
        'x-badge-app': app,
        'x-badge-id': 'B1',
        'x-badge-user': 'u1',
        'x-badge-time': String(time),
        'x-badge-request': id,
        'x-badge-key': 'k1',
        'x-badge-signature': sig.toString('base64'),
      };
      return (n: string) => h[n] ?? '';
    };
    return { url, sign };
  }

  it('accepts a good request once and refuses replays, old times, other apps and edits', async () => {
    const t = 1_790_000_000_000;
    const { url, sign } = await signer();
    const v = new Verifier('intro-bot', url, () => t);
    const U = 'https://relay.botbotcap.com/api/board';
    const h = await sign('GET', U, '', t, 'r1');
    expect(await v.check('GET', U, '', h)).toEqual({ badge: 'B1', user: 'u1' });
    expect(await v.check('GET', U, '', h)).toBeNull(); // replay
    expect(await v.check('GET', U, '', await sign('GET', U, '', t - 61_000, 'r2'))).toBeNull(); // old
    expect(await v.check('GET', U, '', await sign('GET', U, '', t, 'r3', 'other'))).toBeNull(); // other app
    expect(await v.check('POST', U, '{}', await sign('POST', U, '{"x":1}', t, 'r4'))).toBeNull(); // body changed
    expect(await v.check('GET', `${U}?x`, '', await sign('GET', U, '', t, 'r5'))).toBeNull(); // url changed
  });
});
