// Intro Bot server on Railway (relay.botbotcap.com). Every /api call must carry the badge
// server's signed X-Badge-* headers. State is one JSON file on a volume (DATA_DIR).
//
//   ESCROW_KEY=... APP_KEY=... DATA_DIR=/data node src/server.ts
import { createServer, type IncomingMessage } from 'node:http';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { App, Err, emptyState, type Bank, type State } from './api.ts';
import { BadgeBank } from './bank.ts';
import { Verifier, type Caller } from './verify.ts';

export const APP_ID = 'intro-bot';
export const ESCROW = 'ESC-GQD4T2WC';

export function load(file: string): State {
  try {
    return { ...emptyState(), ...(JSON.parse(readFileSync(file, 'utf8')) as Partial<State>) };
  } catch {
    return emptyState();
  }
}

/** Routes one signed request. Exported for tests. */
export async function route(app: App, method: string, path: string, c: Caller, body: Record<string, unknown>) {
  const p = path.split('/').filter(Boolean); // ["api", ...]
  if (p[0] !== 'api') throw new Err(404, 'not found');
  const [, a, id, act] = p;
  if (method === 'GET') {
    if (a === 'board' && !id) return app.board(c);
    if (a === 'me' && !id) return app.me(c);
    if (a === 'fleet' && !id) return app.fleet();
    if (a === 'jobs' && id && !act) return app.job(c, id);
  } else if (method === 'POST') {
    if (a === 'introer' && !id) return app.register(c, body);
    if (a === 'log' && !id) {
      // What the badge OS answered (e.g. a refused deposit), so it shows in the logs.
      console.log('badge log', c.badge, c.user, JSON.stringify(body).slice(0, 300));
      return { ok: true };
    }
    if (a === 'jobs' && !id) return { ...app.post(c, body), esc: ESCROW };
    if (a === 'jobs' && id && act === 'bonus') return app.bonus(c, id, body);
    if (a === 'jobs' && id && act) return app.act(c, id, act, body);
  }
  throw new Err(404, 'not found');
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of req) {
    n += (c as Buffer).length;
    if (n > 4096) throw new Err(413, 'too big');
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export function serve(opts: {
  bank: Bank;
  file: string;
  publicUrl: string;
  keyUrl: string;
  port: number;
  tickMs?: number;
}) {
  const state = load(opts.file);
  let dirty = false;
  const app = new App(state, opts.bank, Date.now, () => {
    dirty = true;
  });
  const flush = () => {
    if (!dirty) return;
    dirty = false;
    writeFileSync(`${opts.file}.tmp`, JSON.stringify(app.s));
    renameSync(`${opts.file}.tmp`, opts.file);
  };
  const verifier = new Verifier(APP_ID, opts.keyUrl);
  let busy = false;
  const timer = setInterval(async () => {
    if (busy) return;
    busy = true;
    await app.tick();
    flush();
    busy = false;
  }, opts.tickMs ?? 10_000);

  const server = createServer(async (req, res) => {
    const send = (status: number, v: unknown) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(v));
    };
    try {
      const path = (req.url ?? '/').split('?')[0] ?? '/';
      if (req.method === 'GET' && path === '/health') return res.end('ok');
      const raw = await readBody(req);
      const h = (n: string) => String(req.headers[n] ?? '');
      // The badge server signs the https URL it asked for; Railway hands us the path.
      const c = await verifier.check(req.method ?? 'GET', `${opts.publicUrl}${req.url ?? '/'}`, raw, h);
      if (!c) return send(401, { error: 'not from the badge' });
      let body: Record<string, unknown> = {};
      if (raw) {
        try {
          body = JSON.parse(raw) as Record<string, unknown>;
        } catch {
          return send(400, { error: 'bad json' });
        }
      }
      const out = await route(app, req.method ?? 'GET', path, c, body);
      flush();
      send(200, out);
    } catch (e) {
      flush();
      if (e instanceof Err) return send(e.status, { error: e.message });
      console.error(e);
      send(500, { error: 'server error' });
    }
  });
  server.listen(opts.port, () => console.log(`intro-bot on :${opts.port}`));
  server.on('close', () => clearInterval(timer));
  return server;
}

if (import.meta.main) {
  const dir = process.env.DATA_DIR ?? './data';
  mkdirSync(dir, { recursive: true });
  const base = process.env.BADGE_API ?? 'https://badge-api.solana.com';
  const escrowKey = process.env.ESCROW_KEY ?? '';
  const appKey = process.env.APP_KEY ?? '';
  if (!escrowKey || !appKey) console.error('ESCROW_KEY and APP_KEY are needed for payouts and meets');
  serve({
    bank: new BadgeBank(base, escrowKey, appKey),
    file: join(dir, 'state.json'),
    publicUrl: process.env.PUBLIC_URL ?? 'https://relay.botbotcap.com',
    keyUrl: `${base}/api/http/key`,
    port: Number(process.env.PORT ?? 8787),
    tickMs: Number(process.env.TICK_MS ?? 10_000),
  });
}
