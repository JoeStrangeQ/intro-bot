// The "phone wallet" for the local end-to-end test. It plays the Solana Pay
// side of a badge QR: GET and POST the relay link, sign, send, confirm.
//
//   node wallet.mjs pay <solana:link> <keypair.json>   -> {"signature": ...}
//   node wallet.mjs init-config <admin keypair.json>   (admin only: the relay refuses it)
//   node wallet.mjs init-stats <admin keypair.json>    (admin only; skipped if Stats exists)
//
// RPC_URL (default http://127.0.0.1:8899). Local keys only, made by e2e.sh.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from '@solana/web3.js';

const RPC_URL = process.env.RPC_URL ?? 'http://127.0.0.1:8899';
const PROGRAM = new PublicKey('GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC');
const LOADER = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111');
const connection = new Connection(RPC_URL, 'confirmed');

const load = (path) =>
  Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path, 'utf8'))));
const disc = (name) => createHash('sha256').update(`global:${name}`).digest().subarray(0, 8);

// Confirm against the blockhash the transaction was signed with (a fresh one could
// outlive it); a blockhash is good for 150 blocks.
async function send(tx) {
  const height = await connection.getBlockHeight('confirmed');
  const signature = await connection.sendRawTransaction(tx.serialize(), {
    preflightCommitment: 'confirmed',
  });
  const res = await connection.confirmTransaction(
    { signature, blockhash: tx.recentBlockhash, lastValidBlockHeight: height + 150 },
    'confirmed',
  );
  if (res.value.err) throw new Error(`tx failed: ${JSON.stringify(res.value.err)}`);
  return signature;
}

// Solana Pay transaction request: solana:<url>, the url percent-encoded if it has a query.
async function pay(link, keypair) {
  if (!link.startsWith('solana:')) throw new Error('not a solana: link');
  let url = link.slice('solana:'.length);
  if (!/^https?:\/\//.test(url)) url = decodeURIComponent(url);
  const headers = { 'content-type': 'application/json', 'cf-connecting-ip': '127.0.0.1' };
  const info = await fetch(url, { headers });
  if (!info.ok) throw new Error(`GET ${info.status}: ${await info.text()}`);
  const { label } = await info.json();
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ account: keypair.publicKey.toBase58() }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`POST ${res.status}: ${body.error}`);
  const tx = Transaction.from(Buffer.from(body.transaction, 'base64'));
  if (!tx.feePayer?.equals(keypair.publicKey)) throw new Error('fee payer is not this wallet');
  tx.partialSign(keypair);
  return { label, signature: await send(tx) };
}

async function initConfig(admin) {
  const pda = (seed) => PublicKey.findProgramAddressSync([Buffer.from(seed)], PROGRAM)[0];
  const [programData] = PublicKey.findProgramAddressSync([PROGRAM.toBuffer()], LOADER);
  const ix = new TransactionInstruction({
    programId: PROGRAM,
    keys: [
      { pubkey: admin.publicKey, isSigner: true, isWritable: true },
      { pubkey: pda('config'), isSigner: false, isWritable: true },
      { pubkey: pda('board'), isSigner: false, isWritable: true },
      { pubkey: PROGRAM, isSigner: false, isWritable: false },
      { pubkey: programData, isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: disc('init_config'),
  });
  const tx = new Transaction().add(ix);
  tx.feePayer = admin.publicKey;
  tx.recentBlockhash = (await connection.getLatestBlockhash('confirmed')).blockhash;
  tx.sign(admin);
  return { signature: await send(tx) };
}

// The fleet totals (Stats), admin only. Does nothing when it already exists.
async function initStats(admin) {
  const pda = (seed) => PublicKey.findProgramAddressSync([Buffer.from(seed)], PROGRAM)[0];
  if (await connection.getAccountInfo(pda('stats'), 'confirmed')) return { skipped: 'stats exists' };
  const ix = new TransactionInstruction({
    programId: PROGRAM,
    keys: [
      { pubkey: admin.publicKey, isSigner: true, isWritable: true },
      { pubkey: pda('config'), isSigner: false, isWritable: false },
      { pubkey: pda('stats'), isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: disc('init_stats'),
  });
  const tx = new Transaction().add(ix);
  tx.feePayer = admin.publicKey;
  tx.recentBlockhash = (await connection.getLatestBlockhash('confirmed')).blockhash;
  tx.sign(admin);
  return { signature: await send(tx) };
}

const [cmd, a, b] = process.argv.slice(2);
try {
  const out =
    cmd === 'pay'
      ? await pay(a, load(b))
      : cmd === 'init-config'
        ? await initConfig(load(a))
        : cmd === 'init-stats'
          ? await initStats(load(a))
          : null;
  if (!out) throw new Error('usage: wallet.mjs pay <link> <keypair> | init-config <keypair> | init-stats <keypair>');
  console.log(JSON.stringify(out));
} catch (err) {
  const logs = err.logs ?? err.transactionLogs;
  console.log(JSON.stringify({ error: String(err.message ?? err) + (err.cause ? ` (${err.cause.message ?? err.cause})` : ""), logs }));
  process.exit(1);
}
