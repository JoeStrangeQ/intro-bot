// Worker entry. workerd treats every named export as an entrypoint, so only
// the handler and the Durable Object class are exported here; the logic and
// its helpers live in relay.ts.
import { handle, TxStore, type Env } from './relay';

export { TxStore };

export default {
  fetch: (req: Request, env: Env) => handle(req, env),
};
