// Node entry for Railway: the same relay (relay.ts), with the Durable Object
// store and the rate limiter kept in memory. One instance only: links live
// 10 minutes, so a restart just means scanning a new QR.
//
//   PORT=8787 RPC_URL=<mainnet rpc> node src/server.ts
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { handle, TxStore, type Env } from './relay.ts';

const ICON = readFileSync(new URL('../public/icon.png', import.meta.url));

// TxStore with in-memory storage; the alarm becomes a timer.
function memoryNamespace() {
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
            deleteAll: async () => void objects.delete(name),
            setAlarm: async (at) =>
              void setTimeout(() => objects.delete(name), at - Date.now()).unref(),
          },
        });
        objects.set(name, obj);
      }
      return obj;
    },
  };
}

// Fixed one-minute windows per key, like the Workers rate limiter.
function memoryLimiter(limit: number) {
  const hits = new Map<string, number>();
  setInterval(() => hits.clear(), 60_000).unref();
  return {
    limit: async ({ key }: { key: string }) => {
      const n = (hits.get(key) ?? 0) + 1;
      hits.set(key, n);
      return { success: n <= limit };
    },
  };
}

const env: Env = {
  RPC_URL: process.env.RPC_URL,
  TX: memoryNamespace(),
  LIMITER: memoryLimiter(60),
};

createServer(async (req, res) => {
  try {
    const host = req.headers.host ?? 'localhost';
    // Railway terminates TLS; the client is the first X-Forwarded-For entry.
    const proto = String(req.headers['x-forwarded-proto'] ?? 'http').split(',')[0];
    const url = new URL(req.url ?? '/', `${proto}://${host}`);
    if (req.method === 'GET' && url.pathname === '/icon.png') {
      res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'max-age=3600' });
      return res.end(ICON);
    }
    if (req.method === 'GET' && url.pathname === '/health') return res.end('ok');
    const ip =
      String(req.headers['x-forwarded-for'] ?? '').split(',')[0]?.trim() ||
      req.socket.remoteAddress ||
      '';
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) {
      if (typeof v === 'string' && k !== 'cf-connecting-ip') headers.set(k, v);
    }
    if (ip) headers.set('cf-connecting-ip', ip);
    const out = await handle(
      new Request(url, { method: req.method, headers, body: req.method === 'GET' ? undefined : body }),
      env,
    );
    const outHeaders: Record<string, string> = {};
    out.headers.forEach((v, k) => (outHeaders[k] = v));
    res.writeHead(out.status, outHeaders);
    res.end(Buffer.from(await out.arrayBuffer()));
  } catch {
    res.writeHead(500).end();
  }
}).listen(Number(process.env.PORT ?? 8787), () => {
  console.log(`relay on :${process.env.PORT ?? 8787}`);
});
