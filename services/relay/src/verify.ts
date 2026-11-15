// Checks the X-Badge-* headers the badge server signs on every request from the app
// (badge docs: `http`, "What your server receives"). Returns the badge and its owner, or null.

export type Caller = { badge: string; user: string };
export type Headers_ = (name: string) => string;

const WINDOW = 60_000;

export class Verifier {
  private keys = new Map<string, CryptoKey>();
  private seen = new Map<string, number>();
  private fetching: Promise<void> | null = null;
  private fetchedAt = 0;

  private readonly app: string;
  private readonly keyUrl: string;
  private readonly now: () => number;

  constructor(app: string, keyUrl: string, now: () => number = Date.now) {
    this.app = app;
    this.keyUrl = keyUrl;
    this.now = now;
  }

  private async key(id: string): Promise<CryptoKey | null> {
    if (!this.keys.has(id) && !this.fetching && this.now() - this.fetchedAt > WINDOW) {
      this.fetchedAt = this.now();
      this.fetching = (async () => {
        const k = (await (await fetch(this.keyUrl)).json()) as { id: string; key: string };
        const raw = Buffer.from(k.key, 'base64');
        this.keys.set(k.id, await crypto.subtle.importKey('raw', raw, 'Ed25519', false, ['verify']));
      })()
        .catch(() => {
          this.fetchedAt = 0;
        })
        .finally(() => {
          this.fetching = null;
        });
    }
    if (!this.keys.has(id) && this.fetching) await this.fetching;
    return this.keys.get(id) ?? null;
  }

  // True the first time a request id comes within the window. No await before it.
  private once(id: string, time: number): boolean {
    for (const [k, t] of this.seen) if (this.now() - t > WINDOW) this.seen.delete(k);
    if (this.seen.has(id)) return false;
    this.seen.set(id, time);
    return true;
  }

  /** `url`: the public https URL the badge asked for. `body`: the raw body. */
  async check(method: string, url: string, body: string, h: Headers_): Promise<Caller | null> {
    const time = Number(h('x-badge-time'));
    const id = h('x-badge-request');
    const user = h('x-badge-user');
    if (h('x-badge-app') !== this.app || !(Math.abs(this.now() - time) < WINDOW) || !id || !user) return null;
    const key = await this.key(h('x-badge-key'));
    if (!key) return null;
    const hash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body))).toString('hex');
    const signed = ['badge-http-v1', method, url, hash, this.app, h('x-badge-id'), user, h('x-badge-time'), id].join('\n');
    const sig = Buffer.from(h('x-badge-signature'), 'base64');
    if (!(await crypto.subtle.verify('Ed25519', key, sig, new TextEncoder().encode(signed)))) return null;
    if (!this.once(id, time)) return null;
    return { badge: h('x-badge-id'), user };
  }
}
