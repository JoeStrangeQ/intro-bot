// Plays the badge server for the simulator: signs a request as a badge (via the fake badge
// API) and sends it to the local Intro Bot server. Body on stdin. Prints {status, body}.
//   node badge-test/call.mjs <METHOD> <https url> <badge> <user>
const [method, url, badge, user] = process.argv.slice(2);
const FAKE = process.env.FAKE ?? 'http://127.0.0.1:8790';
const LOCAL = process.env.LOCAL ?? 'http://127.0.0.1:8791';
const chunks = [];
for await (const c of process.stdin) chunks.push(c);
const body = Buffer.concat(chunks).toString('utf8');
const sign = await fetch(`${FAKE}/test/sign`, {
  method: 'POST',
  body: JSON.stringify({ method, url, body, app: 'intro-bot', badge, user }),
});
const headers = await sign.json();
const u = new URL(url);
const r = await fetch(`${LOCAL}${u.pathname}${u.search}`, {
  method,
  headers: body ? { ...headers, 'content-type': 'application/json' } : headers,
  body: body || undefined,
});
process.stdout.write(JSON.stringify({ status: r.status, body: await r.text() }));
