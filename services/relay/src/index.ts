// Solana Pay relay for the Intro Bot badge (docs/spec.md, "No web app").
// The badge POSTs an unsigned legacy message whose only signer is a
// placeholder; the wallet then fetches it here with its own key and a fresh
// blockhash filled in. Holds nothing but the message, for 10 minutes.
import bs58 from 'bs58';

export const PROGRAM_ID = 'GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC';
const ALLOWED = [
  PROGRAM_ID,
  '11111111111111111111111111111111',
  'ComputeBudget111111111111111111111111111111',
];
export const PLACEHOLDER = new Uint8Array(32).fill(1);
const ORIGIN = 'https://relay.botbotcap.com';
const TTL = 600;
const MAX_MESSAGE = 1232 - 1 - 64; // packet size minus one signature

export type Env = {
  RPC_URL: string;
  TX: KVStore;
  LIMITER?: { limit(o: { key: string }): Promise<{ success: boolean }> };
};
type KVStore = {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, o: { expirationTtl: number }): Promise<void>;
};

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

class Bad extends Error {}

/** Parsed legacy message: where the keys and blockhash sit. */
type Parsed = { keys: Uint8Array[]; keysAt: number; hashAt: number };

function compactU16(b: Uint8Array, at: number): [number, number] {
  let v = 0;
  for (let i = 0; i < 3; i++) {
    const byte = b[at + i];
    if (byte === undefined) throw new Bad('truncated');
    v |= (byte & 0x7f) << (7 * i);
    if (!(byte & 0x80)) return [v, at + i + 1];
  }
  throw new Bad('bad length');
}

const same = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((x, i) => x === b[i]);

/** Enforces the relay rules; throws Bad on any violation. */
export function check(msg: Uint8Array): Parsed {
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
    if (!program || !ALLOWED.includes(bs58.encode(program))) {
      throw new Bad('program not allowed');
    }
    let len: number;
    [len, at] = compactU16(msg, at);
    for (let j = 0; j < len; j++) {
      if ((msg[at++] ?? n) >= n) throw new Bad('bad account index');
    }
    [len, at] = compactU16(msg, at);
    at += len;
  }
  if (at !== msg.length) throw new Bad('trailing or truncated bytes');
  return { keys, keysAt, hashAt };
}

function fromHex(hex: unknown) {
  if (typeof hex !== 'string' || !/^([0-9a-f]{2})+$/i.test(hex)) {
    throw new Bad('message must be hex');
  }
  if (hex.length > MAX_MESSAGE * 2) throw new Bad('message too large');
  return Uint8Array.from(hex.match(/../g)!, (h) => parseInt(h, 16));
}

async function blockhash(env: Env, fetcher: typeof fetch) {
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
  const body = (await res.json()) as {
    result?: { value: { blockhash: string } };
  };
  if (!res.ok || !body.result) throw new Error('rpc failed');
  return bs58.decode(body.result.value.blockhash);
}

export async function handle(
  req: Request,
  env: Env,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  const path = new URL(req.url).pathname.replace(/\/+$/, '');
  try {
    if (path === '/tx' && req.method === 'POST') {
      const ip = req.headers.get('cf-connecting-ip') ?? 'unknown';
      if (env.LIMITER && !(await env.LIMITER.limit({ key: ip })).success) {
        return json({ error: 'slow down' }, 429);
      }
      const body = (await req.json().catch(() => null)) as {
        message?: unknown;
      } | null;
      const msg = fromHex(body?.message);
      check(msg);
      const id = crypto.randomUUID().replace(/-/g, '');
      await env.TX.put(id, body!.message as string, { expirationTtl: TTL });
      return json({ url: `solana:${ORIGIN}/tx/${id}` });
    }
    const id = /^\/tx\/([0-9a-f]{32})$/.exec(path)?.[1];
    if (!id) return json({ error: 'not found' }, 404);
    const hex = await env.TX.get(id);
    if (!hex) return json({ error: 'expired or unknown' }, 404);
    if (req.method === 'GET') {
      return json({ label: 'BotBot Intro Bot', icon: `${ORIGIN}/icon.png` });
    }
    if (req.method !== 'POST') return json({ error: 'not found' }, 404);
    const body = (await req.json().catch(() => null)) as {
      account?: unknown;
    } | null;
    let account: Uint8Array;
    try {
      account = bs58.decode(String(body?.account ?? ''));
    } catch {
      throw new Bad('bad account');
    }
    if (account.length !== 32) throw new Bad('bad account');
    const msg = fromHex(hex);
    const { keys, keysAt, hashAt } = check(msg);
    // The wallet must not already be in the message: keys would merge.
    if (keys.some((k) => same(k, account))) throw new Bad('account in use');
    msg.set(account, keysAt);
    msg.set(await blockhash(env, fetcher), hashAt);
    const tx = new Uint8Array(1 + 64 + msg.length);
    tx[0] = 1; // one empty signature for the wallet to fill
    tx.set(msg, 65);
    return json({
      transaction: btoa(String.fromCharCode(...tx)),
      message: 'Intro Bot by BotBot',
    });
  } catch (err) {
    if (err instanceof Bad) return json({ error: err.message }, 400);
    return json({ error: 'relay error' }, 502);
  }
}

export default {
  fetch: (req: Request, env: Env) => handle(req, env),
};
