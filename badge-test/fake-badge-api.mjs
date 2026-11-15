// A stand-in for badge-api.solana.com, for tests: the signing key, the escrow ledger and
// payouts, and meets. Test hooks under /test let the simulator deposit, meet and sign.
//   node badge-test/fake-badge-api.mjs <port>
import { createServer } from 'node:http';

const port = Number(process.argv[2] ?? 8790);
const kp = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
const pub = Buffer.from(await crypto.subtle.exportKey('raw', kp.publicKey)).toString('base64');
const ledger = [];
const meets = [];
const pays = new Map();

const after = (list, url) => {
  const a = Number(new URL(url, 'http://x').searchParams.get('after') ?? 0);
  return list.filter((x) => x.id > a);
};

async function sign({ method, url, body, app, badge, user }) {
  const time = String(Date.now());
  const id = crypto.randomUUID().replace(/-/g, '').slice(0, 16);
  const hash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body))).toString('hex');
  const msg = ['badge-http-v1', method, url, hash, app, badge, user, time, id].join('\n');
  const sig = Buffer.from(await crypto.subtle.sign('Ed25519', kp.privateKey, new TextEncoder().encode(msg)));
  return {
    'x-badge-app': app,
    'x-badge-id': badge,
    'x-badge-user': user,
    'x-badge-time': time,
    'x-badge-request': id,
    'x-badge-key': 'test-key',
    'x-badge-signature': sig.toString('base64'),
  };
}

createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString('utf8');
  const body = raw ? JSON.parse(raw) : {};
  const send = (v, status = 200) => {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(v));
  };
  const path = (req.url ?? '').split('?')[0];
  const auth = req.headers.authorization ?? '';
  if (path === '/api/http/key') return send({ id: 'test-key', alg: 'Ed25519', key: pub });
  if (path === '/api/escrow/ledger') {
    if (auth !== 'Bearer test-escrow-key') return send({ error: 'key' }, 401);
    return send({ items: after(ledger, req.url), balance: 0 });
  }
  if (path === '/api/escrow/pay') {
    if (auth !== 'Bearer test-escrow-key') return send({ error: 'key' }, 401);
    if (!pays.has(body.key)) pays.set(body.key, body);
    return send({ ok: true });
  }
  if (path === '/api/app/meets') {
    if (auth !== 'Bearer test-app-key') return send({ error: 'key' }, 401);
    return send({ app: 'intro-bot', items: after(meets, req.url) });
  }
  if (path === '/test/deposit') {
    const id = ledger.length + 1;
    ledger.push({ id, type: 'deposit', amount: body.amount, memo: body.memo, user: body.user, badge: body.badge });
    return send({ id: String(id) });
  }
  if (path === '/test/meet') {
    const id = meets.length + 1;
    meets.push({ id, at: Date.now(), by: body.req.badge, bridged: false, req: body.req, acc: body.acc });
    return send({ id });
  }
  if (path === '/test/sign') return send(await sign(body));
  if (path === '/test/pays') return send([...pays.values()]);
  send({ error: 'not found' }, 404);
}).listen(port, () => console.log(`fake badge api on :${port}`));
