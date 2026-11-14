import bs58 from 'bs58';
import { beforeEach, describe, expect, it } from 'vitest';
import { handle, PLACEHOLDER, PROGRAM_ID, type Env } from '../src/index';

const key = (n: number) => new Uint8Array(32).fill(n);
const PROGRAM = bs58.decode(PROGRAM_ID);
const SYSTEM = new Uint8Array(32);
const WALLET = key(7);
const HASH = bs58.encode(key(9));

/** Legacy message: header, keys, zero blockhash, one ix per program index. */
function message({
  signers = 1,
  keys = [PLACEHOLDER, key(2), SYSTEM, PROGRAM],
  programs = [3],
  extra = [] as number[],
} = {}) {
  const ixs = programs.flatMap((p) => [p, 2, 0, 1, 3, 1, 2, 3]);
  const bytes = [
    signers, 0, 2, keys.length,
    ...keys.flatMap((k) => [...k]),
    ...new Uint8Array(32),
    programs.length, ...ixs, ...extra,
  ];
  return Buffer.from(bytes).toString('hex');
}

let store: Map<string, string>;
let env: Env;
const rpc = (async () =>
  Response.json({ result: { value: { blockhash: HASH } } })) as typeof fetch;

beforeEach(() => {
  store = new Map();
  env = {
    RPC_URL: 'https://rpc.test',
    TX: {
      get: async (k) => store.get(k) ?? null,
      put: async (k, v) => void store.set(k, v),
    },
  };
});

const call = (path: string, method = 'GET', body?: unknown) =>
  handle(
    new Request(`https://relay.botbotcap.com${path}`, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
    rpc,
  );

async function post(hex: string) {
  return call('/tx', 'POST', { message: hex });
}

describe('relay', () => {
  it('stores a valid message and fills wallet and blockhash', async () => {
    const res = await post(message({ programs: [3, 2] }));
    expect(res.status).toBe(200);
    const { url } = await res.json();
    expect(url).toMatch(/^solana:https:\/\/relay\.botbotcap\.com\/tx\/[0-9a-f]{32}$/);
    const path = url.slice('solana:https://relay.botbotcap.com'.length);

    const meta = await (await call(path)).json();
    expect(meta).toEqual({
      label: 'BotBot Intro Bot',
      icon: 'https://relay.botbotcap.com/icon.png',
    });

    const out = await call(path, 'POST', { account: bs58.encode(WALLET) });
    expect(out.status).toBe(200);
    const tx = Buffer.from((await out.json()).transaction, 'base64');
    expect(tx[0]).toBe(1);
    expect(tx.subarray(1, 65).every((b) => b === 0)).toBe(true);
    const msg = tx.subarray(65);
    expect([...msg.subarray(4, 36)]).toEqual([...WALLET]);
    expect(bs58.encode(msg.subarray(4 + 4 * 32, 4 + 5 * 32))).toBe(HASH);
  });

  it('rejects a program that is not allowed', async () => {
    const res = await post(message({ keys: [PLACEHOLDER, key(2), SYSTEM, key(5)] }));
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe('program not allowed');
  });

  it('rejects an extra signer', async () => {
    expect((await post(message({ signers: 2 }))).status).toBe(400);
  });

  it('rejects a fee payer that is not the placeholder', async () => {
    const res = await post(message({ keys: [key(3), key(2), SYSTEM, PROGRAM] }));
    expect(res.status).toBe(400);
  });

  it('rejects oversize, trailing bytes and non-hex', async () => {
    expect((await post('ab'.repeat(1200))).status).toBe(400);
    expect((await post(message({ extra: [0] }))).status).toBe(400);
    expect((await post('zz')).status).toBe(400);
    expect((await call('/tx', 'POST', {})).status).toBe(400);
  });

  it('404s for an expired or unknown id', async () => {
    const res = await call(`/tx/${'a'.repeat(32)}`);
    expect(res.status).toBe(404);
    expect((await call('/nope')).status).toBe(404);
  });

  it('rejects a wallet that is already in the message', async () => {
    const { url } = await (await post(message())).json();
    const path = url.slice('solana:https://relay.botbotcap.com'.length);
    const res = await call(path, 'POST', { account: bs58.encode(key(2)) });
    expect(res.status).toBe(400);
    expect((await call(path, 'POST', { account: 'x' })).status).toBe(400);
  });

  it('rate-limits posts per IP', async () => {
    env.LIMITER = { limit: async () => ({ success: false }) };
    expect((await post(message())).status).toBe(429);
  });
});
