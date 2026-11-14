# Deploy intro_escrow to mainnet

Program id: `GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC`.
The program keypair lives at `~/.config/intro-bot/intro_escrow-keypair.json`, never in the repo.

## Plan

1. A hot "deployer" key deploys and runs `init_config` (it becomes admin).
2. Admin moves to the Ledger, arbiter moves to a Squads multisig.
3. Upgrade authority moves to the Ledger.
4. After the checklist passes, the program is made immutable.

A Ledger can't comfortably sign the ~350 buffer writes or a custom Anchor instruction, so
the hot key does those, then hands everything to the Ledger.

## Steps

```sh
# 0. Build and test
anchor build            # or: cargo build-sbf
cargo test && cargo clippy --all-targets -- -D warnings
ls -l target/deploy/intro_escrow.so           # note the size, used as --max-len
cp ~/.config/intro-bot/intro_escrow-keypair.json target/deploy/

# 1. Fund a fresh hot key with ~5 SOL (see costs)
solana-keygen new -o ~/.config/intro-bot/deployer.json
solana config set --url mainnet-beta --keypair ~/.config/intro-bot/deployer.json
LEDGER=$(solana-keygen pubkey usb://ledger)

# 2. Deploy, max-len = .so size (it becomes immutable, no room needed)
solana program deploy target/deploy/intro_escrow.so \
  --program-id ~/.config/intro-bot/intro_escrow-keypair.json \
  --max-len $(stat -f%z target/deploy/intro_escrow.so) \
  --with-compute-unit-price 10000
```

3. Run `init_config(arbiter, cap_total)` signed by the deployer key, e.g. with the
   Anchor TS client and `idl/intro_escrow.json`. Pass the Ledger as a temporary arbiter
   and a small cap to start (for example 50 SOL = `50_000_000_000`).

4. `set_admin(<LEDGER>)` (signed by deployer), then `set_arbiter(<SQUADS VAULT>)`
   (signed by the Ledger, the new admin). Check: `anchor account Config <config PDA>`.

```sh
# 5. Upgrade authority to the Ledger
solana program set-upgrade-authority GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC \
  --new-upgrade-authority $LEDGER --skip-new-upgrade-authority-signer-check
solana program show GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC   # Authority = Ledger

# 6. Run the checklist below, then make it immutable (cannot be undone)
solana program set-upgrade-authority GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC \
  --final --upgrade-authority usb://ledger
```

If a deploy fails midway, `solana program show --buffers` lists the buffer; close it with
`solana program close <buffer>` to get its SOL back.

## Pre-immutability checklist

- [ ] Deployed code matches the reviewed commit: `solana-verify` or
      `solana program dump <id> out.so` and compare hash with `target/deploy/intro_escrow.so`.
- [ ] `Config` exists: admin = Ledger, arbiter = Squads vault, `paused = false`, cap set.
- [ ] Squads vault address is the vault PDA (not the multisig account) and can sign.
- [ ] Ledger can sign `set_paused` (test pause and unpause once).
- [ ] One full real job on mainnet with a small bid: register, bid, accept, made, confirm.
      Introer got the bid, requester got the rent back, `total_held` back to 0.
- [ ] One refund path (withdraw) and one dispute resolved by Squads.
- [ ] Web app, Worker and badge point at this program id.
- [ ] IDL in repo matches the deployed build.
- [ ] Everyone agrees: no more code changes are possible after `--final`.

## Cost estimate (from the built .so, 342,160 bytes)

Rent = `(128 + bytes) × 6,960` lamports (same as `solana rent <bytes>`).

| Item | Bytes | SOL | Kept? |
| --- | --- | --- | --- |
| ProgramData (45 + .so, `--max-len` = .so size) | 342,205 | 2.3826 | locked forever once immutable |
| Program account | 36 | 0.0011 | locked |
| Buffer during deploy (37 + .so) | 342,197 | 2.3826 | returned after deploy |
| Deploy tx fees (~350 writes × 5,000 + priority) | | ~0.002–0.01 | spent |
| Config account | 90 | 0.0015 | locked |
| Each introer (paid by introer) | 154 | 0.0020 | stays |
| Each request (paid by requester) | 218 | 0.0024 | returned to requester on settle |

Net cost: about **2.39 SOL**. Have about **4.8 SOL** in the deployer key during deploy, since
the buffer is funded before it is returned.
