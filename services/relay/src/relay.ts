// Solana Pay relay for the Intro Bot badge (docs/spec.md, "No web app").
// The badge POSTs an unsigned legacy message whose only signer is a
// placeholder; the wallet then fetches it here with its own key and a fresh
// blockhash filled in. Holds nothing but the message, for 10 minutes.
import bs58 from 'bs58';
import { ed25519 } from '@noble/curves/ed25519';
import { sha256 } from '@noble/hashes/sha2';

// Only intro_escrow may be called at the top level. It moves SOL by CPI, so
// System stays allowed as an account but never as a program.
export const PROGRAM_ID = 'GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC';
const PROGRAM = bs58.decode(PROGRAM_ID);
// User-facing escrow instructions (spec v2) by Anchor discriminator, from
// idl/intro_escrow.json. Admin ones (init_config, set_paused,
// propose_admin, accept_admin, cancel_admin_proposal) are refused.
export const ALLOWED_IX: Record<string, string> = {
  '7bdef1c58acb8cf2': 'register_introer',
  '69fe06de8958fa50': 'update_introer',
  '22d03af881eab3d3': 'post_job',
  '7ef19bf132ec5376': 'cancel_job',
  '35cc245a970636e7': 'offer',
  cb2683eacc7a3596: 'withdraw_offer',
  bf484323efd16184: 'close_offer',
  '454ad9247375614c': 'approve',
  '8aacbff25a16c159': 'mark_made',
  ae010fd503be8300: 'confirm',
  '7699a4f42880f2fa': 'refund_expired',
  f3e95327b0f588d8: 'refund_unconfirmed',
};
const toHex = (b: Uint8Array) =>
  Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
export const PLACEHOLDER = new Uint8Array(32).fill(1);
const TTL_MS = 600_000;
// Addresses made from the wallet (the job, the introer, the offer) can't be
// built on the badge before the wallet is known. The badge puts 32 x (2 + i)
// at those keys and sends their seeds, "wallet" standing for the wallet; the
// relay derives them once the wallet scans.
const MAX_PDAS = 2;
const pdaHolder = (i: number) => new Uint8Array(32).fill(2 + i);
export type PdaSpec = { at: number; seeds: string[] };
const MAX_MESSAGE = 1232 - 1 - 64; // packet size minus one signature
const MAX_BODY = MAX_MESSAGE * 2 + 64;
const BLOCKHASH_MS = 5_000;
// "Connect" links carry no badge message: the wallet signs a memo, and the
// badge learns the wallet's address from /tx/<id>/who. No typing.
const CONNECT = 'connect';
const MEMO = bs58.decode('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr');
const MEMO_TEXT = new TextEncoder().encode('Intro Bot by BotBot: connect badge');

type Stub = { fetch(req: Request): Promise<Response> };
export type Env = {
  /** Set per environment; see services/relay/README.md. */
  RPC_URL?: string;
  TX: { idFromName(name: string): unknown; get(id: unknown): Stub };
  LIMITER?: { limit(o: { key: string }): Promise<{ success: boolean }> };
};

type Entry = { m: string; exp: number; by?: string };
type Storage = {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  deleteAll(): Promise<void>;
  setAlarm(at: number): Promise<void>;
};

/** One Durable Object per id: strongly consistent, read right after write. */
export class TxStore {
  private state: { storage: Storage };
  constructor(state: { storage: Storage }) {
    this.state = state;
  }
  async fetch(req: Request) {
    const s = this.state.storage;
    if (req.method === 'PUT') {
      const exp = Date.now() + TTL_MS;
      await s.put('t', { m: await req.text(), exp });
      await s.setAlarm(exp);
      return new Response('ok');
    }
    const t = await s.get<Entry>('t');
    if (!t || Date.now() > t.exp) return new Response(null, { status: 404 });
    if (new URL(req.url).pathname.endsWith('/who')) {
      return new Response(t.by ?? '');
    }
    if (req.method === 'POST') {
      // Claim for one wallet; that wallet may retry, others get 404.
      const account = await req.text();
      if (t.by && t.by !== account) return new Response(null, { status: 404 });
      if (!t.by) await s.put('t', { ...t, by: account });
    }
    return new Response(t.m);
  }
  alarm() {
    return this.state.storage.deleteAll();
  }
}

const store = (
  env: Env,
  id: string,
  method: string,
  body?: string,
  sub = '',
) =>
  env.TX.get(env.TX.idFromName(id)).fetch(
    new Request(`https://store/${id}${sub}`, { method, body }),
  );

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...CORS },
  });

class Bad extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

export function compactU16(b: Uint8Array, at: number): [number, number] {
  let v = 0;
  for (let i = 0; i < 3; i++) {
    const byte = b[at + i];
    if (byte === undefined) throw new Bad('truncated');
    // The third byte holds only the top 2 bits of a u16.
    if (i === 2 && byte > 0x03) throw new Bad('bad length');
    // Minimal encoding only, like the runtime: no trailing zero byte.
    if (i > 0 && byte === 0) throw new Bad('bad length');
    v |= (byte & 0x7f) << (7 * i);
    if (!(byte & 0x80)) return [v, at + i + 1];
  }
  throw new Bad('bad length');
}

const same = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((x, i) => x === b[i]);

/** Program address for these seeds (the first bump off the curve). */
export function findPda(seeds: Uint8Array[], program: Uint8Array) {
  const tag = new TextEncoder().encode('ProgramDerivedAddress');
  for (let bump = 255; bump >= 0; bump--) {
    const parts = [...seeds, Uint8Array.of(bump), program, tag];
    const buf = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let o = 0;
    for (const p of parts) buf.set(p, (o += p.length) - p.length);
    const hash = sha256(buf);
    try {
      ed25519.ExtendedPoint.fromHex(hash);
    } catch {
      return hash;
    }
  }
  throw new Bad('no program address');
}

/** Each spec points at its own holder key; seeds are hex (<= 32 bytes) or "wallet", once. */
export function checkPdas(keys: Uint8Array[], pdas: unknown): PdaSpec[] {
  if (pdas === undefined) return [];
  if (!Array.isArray(pdas) || pdas.length > MAX_PDAS) throw new Bad('bad pdas');
  return pdas.map((p: unknown, i) => {
    const { at, seeds } = (p ?? {}) as { at?: unknown; seeds?: unknown };
    if (typeof at !== 'number' || !Number.isInteger(at) || !keys[at] || !same(keys[at], pdaHolder(i))) {
      throw new Bad('bad pdas');
    }
    if (!Array.isArray(seeds) || seeds.length < 2 || seeds.length > 8) throw new Bad('bad pdas');
    if (seeds.filter((x) => x === 'wallet').length !== 1) throw new Bad('bad pdas');
    for (const x of seeds) {
      if (x !== 'wallet' && (typeof x !== 'string' || !/^([0-9a-f]{2}){1,32}$/.test(x))) {
        throw new Bad('bad pdas');
      }
    }
    return { at, seeds: seeds as string[] };
  });
}

/** Enforces the relay rules; throws Bad on any violation. */
export function check(msg: Uint8Array) {
  if (msg.length > MAX_MESSAGE) throw new Bad('message too large');
  const [sigs, roSigned, roUnsigned] = msg;
  if (sigs === undefined || sigs & 0x80) throw new Bad('legacy messages only');
  if (sigs !== 1) throw new Bad('placeholder must be the only signer');
  if (roSigned !== 0) throw new Bad('fee payer must be writable');
  let [n, at] = compactU16(msg, 3);
  const keysAt = at;
  const keys: Uint8Array[] = [];
  for (let i = 0; i < n; i++, at += 32) {
    if (at + 32 > msg.length) throw new Bad('truncated');
    keys.push(msg.subarray(at, at + 32));
  }
  if (!keys[0] || !same(keys[0], PLACEHOLDER)) {
    throw new Bad('fee payer must be the placeholder');
  }
  if (keys.slice(1).some((k) => same(k, PLACEHOLDER))) {
    throw new Bad('placeholder used twice');
  }
  if ((roUnsigned ?? 0) > n - 1) throw new Bad('bad header');
  const hashAt = at;
  at += 32;
  let ixs: number;
  [ixs, at] = compactU16(msg, at);
  if (ixs === 0) throw new Bad('no instructions');
  for (let i = 0; i < ixs; i++) {
    const program = keys[msg[at++] ?? n];
    if (!program || !same(program, PROGRAM)) {
      throw new Bad('program not allowed');
    }
    let len: number;
    [len, at] = compactU16(msg, at);
    for (let j = 0; j < len; j++) {
      if ((msg[at++] ?? n) >= n) throw new Bad('bad account index');
    }
    [len, at] = compactU16(msg, at);
    if (at + len > msg.length) throw new Bad('truncated');
    if (!ALLOWED_IX[toHex(msg.subarray(at, at + Math.min(len, 8)))]) {
      throw new Bad('instruction not allowed');
    }
    at += len;
  }
  if (at !== msg.length) throw new Bad('trailing or truncated bytes');
  return { keys, keysAt, hashAt };
}

function fromHex(hex: unknown) {
  if (typeof hex !== 'string') throw new Bad('message must be hex');
  if (hex.length > MAX_MESSAGE * 2) throw new Bad('message too large');
  if (!/^([0-9a-f]{2})+$/i.test(hex)) throw new Bad('message must be hex');
  return Uint8Array.from(hex.match(/../g)!, (h) => parseInt(h, 16));
}

/** Small JSON body, size checked before parsing. */
async function readJson(req: Request): Promise<Record<string, unknown>> {
  if (Number(req.headers.get('content-length') ?? 0) > MAX_BODY) {
    throw new Bad('body too large', 413);
  }
  const text = await req.text();
  if (text.length > MAX_BODY) throw new Bad('body too large', 413);
  try {
    const body: unknown = JSON.parse(text);
    if (body && typeof body === 'object') {
      return body as Record<string, unknown>;
    }
  } catch {
    // fall through
  }
  throw new Bad('body must be JSON');
}

let cached: { url: string; hash: Uint8Array; at: number } | null = null;

export async function blockhash(env: Env, fetcher: typeof fetch) {
  if (!env.RPC_URL) throw new Error('RPC_URL is not set');
  if (cached?.url === env.RPC_URL && Date.now() - cached.at < BLOCKHASH_MS) {
    return cached.hash;
  }
  const res = await fetcher(env.RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'getLatestBlockhash',
      params: [{ commitment: 'confirmed' }],
    }),
  });
  if (!res.ok) throw new Error(`rpc http ${res.status}`);
  const body = (await res.json()) as {
    result?: { value?: { blockhash?: unknown } };
  };
  const text = body.result?.value?.blockhash;
  if (typeof text !== 'string') throw new Error('rpc: no blockhash');
  const hash = bs58.decode(text);
  if (hash.length !== 32) throw new Error('rpc: bad blockhash');
  cached = { url: env.RPC_URL, hash, at: Date.now() };
  return hash;
}

/** A one-memo transaction signed by `wallet`, proving the connect scan. */
export function memoTx(wallet: Uint8Array, hash: Uint8Array) {
  const msg = new Uint8Array([
    ...[1, 0, 1, 2],
    ...wallet,
    ...MEMO,
    ...hash,
    ...[1, 1, 0, MEMO_TEXT.length],
    ...MEMO_TEXT,
  ]);
  const tx = new Uint8Array(1 + 64 + msg.length);
  tx[0] = 1;
  tx.set(msg, 65);
  return tx;
}

export async function handle(
  req: Request,
  env: Env,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, '');
  // Each kind of call gets its own per-IP bucket, checked only on real routes.
  const limit = async (kind: string) => {
    // Cloudflare always sets this; without it there is no fair bucket.
    const ip = req.headers.get('cf-connecting-ip');
    if (!ip) throw new Bad('no client ip');
    if (
      env.LIMITER &&
      !(await env.LIMITER.limit({ key: `${kind}:${ip}` })).success
    ) {
      throw new Bad('slow down', 429);
    }
  };
  try {
    if (path === '/tx' && req.method === 'POST') {
      await limit('create');
      const { message, pdas } = await readJson(req);
      const specs = checkPdas(check(fromHex(message)).keys, pdas);
      const id = crypto.randomUUID().replace(/-/g, '');
      const put = await store(
        env,
        id,
        'PUT',
        specs.length ? JSON.stringify({ m: message, p: specs }) : (message as string),
      );
      if (!put.ok) throw new Error('store failed');
      return json({ url: `solana:${url.origin}/tx/${id}` });
    }
    if (path === '/connect' && req.method === 'POST') {
      await limit('create');
      const id = crypto.randomUUID().replace(/-/g, '');
      const put = await store(env, id, 'PUT', CONNECT);
      if (!put.ok) throw new Error('store failed');
      return json({ id, url: `solana:${url.origin}/tx/${id}` });
    }
    const who = /^\/tx\/([0-9a-f]{32})\/who$/.exec(path)?.[1];
    if (who && req.method === 'GET') {
      await limit('read');
      const found = await store(env, who, 'GET', undefined, '/who');
      if (!found.ok) return json({ error: 'expired or unknown' }, 404);
      return json({ wallet: (await found.text()) || null });
    }
    const id = /^\/tx\/([0-9a-f]{32})$/.exec(path)?.[1];
    if (!id || (req.method !== 'GET' && req.method !== 'POST')) {
      return json({ error: 'not found' }, 404);
    }
    if (req.method === 'GET') {
      await limit('read');
      if (!(await store(env, id, 'GET')).ok) {
        return json({ error: 'expired or unknown' }, 404);
      }
      return json({
        label: 'BotBot Intro Bot',
        icon: `${url.origin}/icon.png`,
      });
    }
    await limit('sign');
    const { account: text } = await readJson(req);
    let account: Uint8Array;
    try {
      account = bs58.decode(String(text ?? ''));
    } catch {
      throw new Bad('bad account');
    }
    if (account.length !== 32) throw new Bad('bad account');
    const hash = blockhash(env, fetcher);
    hash.catch(() => {});
    const found = await store(env, id, 'POST', bs58.encode(account));
    if (!found.ok) return json({ error: 'expired or unknown' }, 404);
    const stored = await found.text();
    if (stored === CONNECT) {
      return json({
        transaction: btoa(String.fromCharCode(...memoTx(account, await hash))),
        message: 'Connect your badge to Intro Bot',
      });
    }
    const saved = stored.startsWith('{')
      ? (JSON.parse(stored) as { m: string; p: PdaSpec[] })
      : { m: stored, p: [] };
    const msg = fromHex(saved.m);
    const { keys, keysAt, hashAt } = check(msg);
    // The wallet must not already be in the message: keys would merge.
    if (keys.some((k) => same(k, account))) throw new Bad('account in use');
    msg.set(account, keysAt);
    for (const { at, seeds } of saved.p) {
      const pda = findPda(
        seeds.map((x) => (x === 'wallet' ? account : fromHex(x))),
        PROGRAM,
      );
      if (keys.some((k, i) => i !== at && same(k, pda))) throw new Bad('account in use');
      msg.set(pda, keysAt + at * 32);
    }
    msg.set(await hash, hashAt);
    const tx = new Uint8Array(1 + 64 + msg.length);
    tx[0] = 1; // one empty signature for the wallet to fill
    tx.set(msg, 65);
    return json({
      transaction: btoa(String.fromCharCode(...tx)),
      message: 'Intro Bot by BotBot',
    });
  } catch (err) {
    if (err instanceof Bad) return json({ error: err.message }, err.status);
    return json({ error: 'relay error' }, 502);
  }
}
