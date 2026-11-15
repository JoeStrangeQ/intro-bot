import bs58 from 'bs58';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  blockhash,
  compactU16,
  handle,
  PLACEHOLDER,
  PROGRAM_ID,
  ALLOWED_IX,
  TxStore,
  type Env,
} from '../src/relay';

const key = (n: number) => new Uint8Array(32).fill(n);
const PROGRAM = bs58.decode(PROGRAM_ID);
const SYSTEM = new Uint8Array(32);
const BUDGET = bs58.decode('ComputeBudget111111111111111111111111111111');
const WALLET = key(7);
const HASH = bs58.encode(key(9));
const ORIGIN = 'https://relay.botbotcap.com';

/** Legacy message: header, keys, zero blockhash, one ix per program index. */
function message({
  signers = 1,
  keys = [PLACEHOLDER, key(2), SYSTEM, PROGRAM],
  programs = [3],
  extra = [] as number[],
  disc = [...Buffer.from('22d03af881eab3d3', 'hex')], // post_job
  data = [1, 2, 3],
} = {}) {
  const ixs = programs.flatMap((p) => [
    p,
    2,
    0,
    1,
    disc.length + data.length,
    ...disc,
    ...data,
  ]);
  const bytes = [
    ...[signers, 0, 2, keys.length],
    ...keys.flatMap((k) => [...k]),
    ...new Uint8Array(32),
    ...[programs.length, ...ixs, ...extra],
  ];
  return Buffer.from(bytes).toString('hex');
}

/** In-memory Durable Object namespace running the real TxStore. */
function fakeNamespace() {
  const objects = new Map<string, TxStore>();
  return {
    idFromName: (name: string) => name,
    get(id: unknown) {
      const name = String(id);
      let obj = objects.get(name);
      if (!obj) {
        const data = new Map<string, unknown>();
        obj = new TxStore({
          storage: {
            get: async <T>(k: string) => data.get(k) as T | undefined,
            put: async (k, v) => void data.set(k, v),
            deleteAll: async () => data.clear(),
            setAlarm: async () => {},
          },
        });
        objects.set(name, obj);
      }
      return obj;
    },
  };
}

let env: Env;
let rpcCalls = 0;
const rpc = (async () => {
  rpcCalls++;
  return Response.json({ result: { value: { blockhash: HASH } } });
}) as typeof fetch;

beforeEach(() => {
  env = { RPC_URL: 'https://rpc.test', TX: fakeNamespace() };
});

const call = (
  path: string,
  method = 'GET',
  body?: unknown,
  headers: Record<string, string> = { 'cf-connecting-ip': '203.0.113.9' },
) =>
  handle(
    new Request(`${ORIGIN}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
    rpc,
  );

const post = (hex: string) => call('/tx', 'POST', { message: hex });
const error = async (res: Response) =>
  ((await res.json()) as { error: string }).error;

async function link(hex = message()) {
  const { url } = (await (await post(hex)).json()) as { url: string };
  return url.slice(`solana:${ORIGIN}`.length);
}

describe('relay', () => {
  it('stores a valid message and fills wallet and blockhash', async () => {
    const res = await post(message({ programs: [3, 3] }));
    expect(res.status).toBe(200);
    const { url } = (await res.json()) as { url: string };
    expect(url).toMatch(
      /^solana:https:\/\/relay\.botbotcap\.com\/tx\/[0-9a-f]{32}$/,
    );
    const path = url.slice(`solana:${ORIGIN}`.length);

    // Readable at once (Durable Object, not eventually consistent KV).
    expect(await (await call(path)).json()).toEqual({
      label: 'BotBot Intro Bot',
      icon: `${ORIGIN}/icon.png`,
    });

    const out = await call(path, 'POST', { account: bs58.encode(WALLET) });
    expect(out.status).toBe(200);
    const { transaction } = (await out.json()) as { transaction: string };
    const tx = Buffer.from(transaction, 'base64');
    expect(tx[0]).toBe(1);
    expect(tx.subarray(1, 65).every((b) => b === 0)).toBe(true);
    const msg = tx.subarray(65);
    expect([...msg.subarray(4, 36)]).toEqual([...WALLET]);
    expect(bs58.encode(msg.subarray(4 + 4 * 32, 4 + 5 * 32))).toBe(HASH);
  });

  it('rejects a top-level System instruction (e.g. a transfer)', async () => {
    const res = await post(message({ programs: [3, 2] }));
    expect(res.status).toBe(400);
    expect(await error(res)).toBe('program not allowed');
  });

  it('rejects ComputeBudget and unknown programs', async () => {
    const budget = message({ keys: [PLACEHOLDER, key(2), SYSTEM, BUDGET] });
    expect(await error(await post(budget))).toBe('program not allowed');
    const other = message({ keys: [PLACEHOLDER, key(2), SYSTEM, key(5)] });
    expect(await error(await post(other))).toBe('program not allowed');
  });

  it('allows exactly the v2 user-facing escrow instructions', async () => {
    expect(Object.values(ALLOWED_IX).sort()).toEqual(
      [
        'register_introer',
        'update_introer',
        'post_job',
        'cancel_job',
        'offer',
        'withdraw_offer',
        'close_offer',
        'approve',
        'mark_made',
        'confirm',
        'refund_expired',
        'refund_unconfirmed',
      ].sort(),
    );
    for (const hex of Object.keys(ALLOWED_IX)) {
      const res = await post(message({ disc: [...Buffer.from(hex, 'hex')] }));
      expect(res.status, ALLOWED_IX[hex]).toBe(200);
    }
  });

  it('refuses admin, removed v1 and unknown escrow instructions', async () => {
    const admin = {
      init_config: '17eb73e8a86001e7',
      set_admin: 'fba300345bc2bb5c',
      set_paused: '5b3c7dc0b0e1a6da',
      set_cap: 'd1cf79817327dc04',
      propose_admin: '79d6c7d4572775ea',
      accept_admin: '702a2d5a74b50daa',
      cancel_admin_proposal: '440691831049b6e5',
      // v1 instructions that no longer exist.
      bid: 'c738552692f3259e',
      accept: '419646d885066b04',
      decline: '18395aa25b5ef5b1',
      withdraw: 'b712469c946da122',
    };
    for (const [name, hex] of Object.entries(admin)) {
      const res = await post(message({ disc: [...Buffer.from(hex, 'hex')] }));
      expect(await error(res), name).toBe('instruction not allowed');
    }
    // Shorter than a discriminator.
    const short = await post(message({ disc: [0xc7, 0x38], data: [] }));
    expect(await error(short)).toBe('instruction not allowed');
  });

  it('rejects an extra signer and a wrong fee payer', async () => {
    expect((await post(message({ signers: 2 }))).status).toBe(400);
    const res = await post(
      message({ keys: [key(3), key(2), SYSTEM, PROGRAM] }),
    );
    expect(await error(res)).toBe('fee payer must be the placeholder');
  });

  it('rejects a v0 message cleanly', async () => {
    const res = await post('80' + message());
    expect(res.status).toBe(400);
    expect(await error(res)).toBe('legacy messages only');
  });

  it('rejects oversize before parsing, trailing bytes and non-hex', async () => {
    const big = await call('/tx', 'POST', { message: 'ab'.repeat(5000) });
    expect(big.status).toBe(413);
    const declared = await call(
      '/tx',
      'POST',
      { message: 'ab' },
      {
        'cf-connecting-ip': '1.2.3.4',
        'content-length': '999999',
      },
    );
    expect(declared.status).toBe(413);
    expect(await error(await post('ab'.repeat(1168)))).toBe(
      'message too large',
    );
    expect((await post(message({ extra: [0] }))).status).toBe(400);
    expect((await post('zz')).status).toBe(400);
    expect((await call('/tx', 'POST', {})).status).toBe(400);
  });

  it('404s for an expired or unknown id', async () => {
    expect((await call(`/tx/${'a'.repeat(32)}`)).status).toBe(404);
    expect((await call('/nope')).status).toBe(404);
  });

  it('GET keeps the id; the first wallet POST claims it', async () => {
    const path = await link();
    expect((await call(path)).status).toBe(200);
    expect((await call(path)).status).toBe(200);
    const account = { account: bs58.encode(WALLET) };
    expect((await call(path, 'POST', account)).status).toBe(200);
    // The same wallet may retry; any other wallet is refused.
    expect((await call(path, 'POST', account)).status).toBe(200);
    const other = { account: bs58.encode(key(8)) };
    expect((await call(path, 'POST', other)).status).toBe(404);
  });

  it('connect: the scanning wallet is reported to the badge', async () => {
    const res = await call('/connect', 'POST', {});
    const { id, url } = (await res.json()) as { id: string; url: string };
    expect(url).toBe(`solana:${ORIGIN}/tx/${id}`);
    const who = () => call(`/tx/${id}/who`).then((r) => r.json());
    expect(await who()).toEqual({ wallet: null });
    const signed = await call(`/tx/${id}`, 'POST', {
      account: bs58.encode(WALLET),
    });
    const { transaction } = (await signed.json()) as { transaction: string };
    const tx = Uint8Array.from(atob(transaction), (c) => c.charCodeAt(0));
    // One empty signature, then the memo message with the wallet as payer.
    expect(Array.from(tx.slice(65, 69))).toEqual([1, 0, 1, 2]);
    expect(Array.from(tx.slice(69, 101))).toEqual(Array.from(WALLET));
    expect(await who()).toEqual({ wallet: bs58.encode(WALLET) });
    expect((await call(`/tx/${'0'.repeat(32)}/who`)).status).toBe(404);
  });

  it('fills wallet-made addresses (PDAs) when the wallet scans', async () => {
    const seeds = ['6a6f62', 'wallet', '0100000000000000']; // "job", wallet, nonce 1
    const res = await call('/tx', 'POST', { message: message(), pdas: [{ at: 1, seeds }] });
    const { url } = (await res.json()) as { url: string };
    const out = await call(url.slice(`solana:${ORIGIN}`.length), 'POST', {
      account: bs58.encode(WALLET),
    });
    const { transaction } = (await out.json()) as { transaction: string };
    const msg = Buffer.from(transaction, 'base64').subarray(65);
    // Same as web3.js findProgramAddressSync(["job", key(7), 1u64], program).
    expect(bs58.encode(msg.subarray(36, 68))).toBe('6acAHV8CdAC9SmAAkouQee6KkCEirWdCAa9JgYchrHXR');
  });

  it('refuses PDA specs that miss the holder key or the wallet', async () => {
    const bad = async (pdas: unknown) =>
      (await call('/tx', 'POST', { message: message(), pdas })).status;
    expect(await bad([{ at: 2, seeds: ['6a6f62', 'wallet'] }])).toBe(400); // System, not a holder
    expect(await bad([{ at: 1, seeds: ['6a6f62', '00'] }])).toBe(400); // no wallet
    expect(await bad([{ at: 1, seeds: ['wallet', 'wallet'] }])).toBe(400);
    expect(await bad([{ at: 1, seeds: ['zz', 'wallet'] }])).toBe(400);
    expect(await bad('x')).toBe(400);
  });

  it('builds links from the serving origin', async () => {
    const res = await handle(
      new Request('http://127.0.0.1:8787/tx', {
        method: 'POST',
        headers: { 'cf-connecting-ip': '1.1.1.1' },
        body: JSON.stringify({ message: message() }),
      }),
      env,
      rpc,
    );
    const { url } = (await res.json()) as { url: string };
    expect(url.startsWith('solana:http://127.0.0.1:8787/tx/')).toBe(true);
  });

  it('rejects a wallet that is already in the message', async () => {
    const path = await link();
    const res = await call(path, 'POST', { account: bs58.encode(key(2)) });
    expect(await error(res)).toBe('account in use');
    expect((await call(path, 'POST', { account: 'x' })).status).toBe(400);
  });

  it('rate-limits both POSTs by CF-Connecting-IP', async () => {
    const path = await link();
    const keys: string[] = [];
    env.LIMITER = {
      limit: async ({ key }) => (keys.push(key), { success: false }),
    };
    expect((await post(message())).status).toBe(429);
    const res = await call(path, 'POST', { account: bs58.encode(WALLET) });
    expect(res.status).toBe(429);
    expect((await call(path)).status).toBe(429);
    expect(keys).toEqual([
      'create:203.0.113.9',
      'sign:203.0.113.9',
      'read:203.0.113.9',
    ]);
  });

  it('rejects POSTs without a client IP', async () => {
    const res = await call('/tx', 'POST', { message: message() }, {});
    expect(res.status).toBe(400);
    expect(await error(res)).toBe('no client ip');
  });

  it('502s when RPC_URL is not set', async () => {
    const path = await link();
    delete env.RPC_URL;
    const res = await call(path, 'POST', { account: bs58.encode(WALLET) });
    expect(res.status).toBe(502);
  });
});

describe('blockhash', () => {
  it('caches for a few seconds', async () => {
    const e = { ...env, RPC_URL: 'https://cache.test' };
    rpcCalls = 0;
    await blockhash(e, rpc);
    await blockhash(e, rpc);
    expect(rpcCalls).toBe(1);
  });

  it('rejects HTTP errors and bad shapes', async () => {
    const answer = (body: unknown, status = 200) =>
      (async () => Response.json(body, { status })) as typeof fetch;
    const e = (url: string) => ({ ...env, RPC_URL: url });
    await expect(blockhash(e('https://a'), answer({}, 500))).rejects.toThrow(
      'http',
    );
    await expect(
      blockhash(e('https://b'), answer({ result: {} })),
    ).rejects.toThrow('no blockhash');
    await expect(
      blockhash(
        e('https://c'),
        answer({ result: { value: { blockhash: 'abc' } } }),
      ),
    ).rejects.toThrow('bad blockhash');
  });
});

describe('compactU16', () => {
  it('reads up to 0xffff and rejects anything larger', () => {
    expect(compactU16(Uint8Array.of(0xff, 0xff, 0x03), 0)).toEqual([0xffff, 3]);
    expect(() => compactU16(Uint8Array.of(0xff, 0xff, 0x04), 0)).toThrow();
    expect(() => compactU16(Uint8Array.of(0x80, 0x80, 0x80), 0)).toThrow();
    // Non-minimal (aliased) encodings are refused, like the runtime.
    expect(() => compactU16(Uint8Array.of(0x80, 0x00), 0)).toThrow();
  });
});
