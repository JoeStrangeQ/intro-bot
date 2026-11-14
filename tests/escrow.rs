//! LiteSVM tests for the intro escrow program (v2). Build first:
//! `cargo build-sbf` (the tests refuse a stale `.so`).
#![allow(clippy::unwrap_used, clippy::expect_used, reason = "tests")]
#![allow(
    clippy::unused_self,
    reason = "builders stay methods for one call style"
)]

use anchor_lang::{
    prelude::Pubkey,
    solana_program::{bpf_loader_upgradeable, instruction::Instruction},
    AccountDeserialize, InstructionData, ToAccountMetas,
};
use intro_escrow::{
    accounts as acc, instruction as ix, Board, Config, Introer, Job, Offer, BOARD_LEN,
    CONFIRM_WINDOW, LAMPORTS_PER_SOL as SOL, MAX_BID, MIN_BID, OFFER_RING, STATUS_APPROVED,
    STATUS_MADE, STATUS_OPEN, TEXT_LEN, WORK_WINDOW,
};
use litesvm::LiteSVM;
use solana_clock::Clock;
use solana_keypair::Keypair;
use solana_signer::Signer;
use solana_transaction::Transaction;

const PROGRAM: &str = "../target/deploy/intro_escrow.so";
const FEE: u64 = 5_000;
/// Half the default per-instruction budget of 200k CU.
const CU_LIMIT: u64 = 100_000;
type Text = [u8; TEXT_LEN];

fn program_data() -> Pubkey {
    Pubkey::find_program_address(&[intro_escrow::ID.as_ref()], &bpf_loader_upgradeable::ID).0
}

fn pda(seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, &intro_escrow::ID).0
}

fn config_key() -> Pubkey {
    pda(&[b"config"])
}

fn board_key() -> Pubkey {
    pda(&[b"board"])
}

fn introer_key(wallet: &Pubkey) -> Pubkey {
    pda(&[b"introer", wallet.as_ref()])
}

fn job_key(requester: &Pubkey, nonce: u64) -> Pubkey {
    pda(&[b"job", requester.as_ref(), &nonce.to_le_bytes()])
}

fn offer_key(job: &Pubkey, wallet: &Pubkey) -> Pubkey {
    pda(&[b"offer", job.as_ref(), wallet.as_ref()])
}

/// Zero-padded text field.
fn pad(text: &str) -> Text {
    let mut out = [0; TEXT_LEN];
    out[..text.len()].copy_from_slice(text.as_bytes());
    out
}

fn build(accounts: impl ToAccountMetas, data: impl InstructionData) -> Instruction {
    Instruction {
        program_id: intro_escrow::ID,
        accounts: accounts.to_account_metas(None),
        data: data.data(),
    }
}

/// Fails if the built program is older than its source, so tests never run
/// a stale `.so`. Rebuild with `cargo build-sbf` (or `anchor build`).
fn check_fresh_build() {
    static CHECKED: std::sync::Once = std::sync::Once::new();
    CHECKED.call_once(|| {
        let modified =
            |path: &std::path::Path| std::fs::metadata(path).unwrap().modified().unwrap();
        let built = modified(std::path::Path::new(PROGRAM));
        let mut sources: Vec<std::path::PathBuf> = [
            "../Cargo.toml",
            "../Cargo.lock",
            "../programs/intro-escrow/Cargo.toml",
        ]
        .iter()
        .map(std::path::PathBuf::from)
        .collect();
        for entry in std::fs::read_dir("../programs/intro-escrow/src").unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|e| e == "rs") {
                sources.push(path);
            }
        }
        for source in sources {
            assert!(
                modified(&source) <= built,
                "{PROGRAM} is older than {}: run `cargo build-sbf`",
                source.display()
            );
        }
    });
}

/// Fresh chain with the program loaded and `authority` (if any) as the
/// upgrade authority in ProgramData.
fn chain(authority: Option<Pubkey>) -> LiteSVM {
    check_fresh_build();
    let mut svm = LiteSVM::new();
    svm.add_program(intro_escrow::ID, &std::fs::read(PROGRAM).unwrap())
        .unwrap();
    if let Some(authority) = authority {
        let key = program_data();
        let mut account = svm.get_account(&key).unwrap();
        account.data[12] = 1;
        account.data[13..45].copy_from_slice(authority.as_ref());
        svm.set_account(key, account).unwrap();
    }
    svm
}

/// Sends `ix` alone, as the relay does, and checks it fits the CU budget.
fn send(svm: &mut LiteSVM, payer: &Keypair, ix: Instruction) -> Result<(), String> {
    svm.expire_blockhash();
    let tx = Transaction::new_signed_with_payer(
        &[ix],
        Some(&payer.pubkey()),
        &[payer],
        svm.latest_blockhash(),
    );
    svm.send_transaction(tx)
        .map(|meta| {
            assert!(
                meta.compute_units_consumed <= CU_LIMIT,
                "used {} CU",
                meta.compute_units_consumed
            );
        })
        .map_err(|e| format!("{:?} {}", e.err, e.meta.logs.join("\n")))
}

#[track_caller]
fn fails(result: Result<(), String>, code: &str) {
    let err = result.expect_err("expected failure");
    assert!(err.contains(code), "expected {code}, got: {err}");
}

fn init_config_ix(authority: Pubkey) -> Instruction {
    build(
        acc::InitConfig {
            authority,
            config: config_key(),
            board: board_key(),
            program: intro_escrow::ID,
            program_data: program_data(),
            system_program: anchor_lang::system_program::ID,
        },
        ix::InitConfig {},
    )
}

fn register_ix(wallet: Pubkey, name: Text) -> Instruction {
    build(
        acc::RegisterIntroer {
            wallet,
            introer: introer_key(&wallet),
            system_program: anchor_lang::system_program::ID,
        },
        ix::RegisterIntroer {
            badge_id: *b"BP26-001",
            name,
        },
    )
}

fn post_ix(requester: Pubkey, nonce: u64, who: Text, telegram: Text, bid: u64) -> Instruction {
    build(
        acc::PostJob {
            requester,
            config: config_key(),
            board: board_key(),
            job: job_key(&requester, nonce),
            system_program: anchor_lang::system_program::ID,
        },
        ix::PostJob {
            nonce,
            who,
            company: pad("Solana"),
            telegram,
            bid,
        },
    )
}

fn cancel_ix(requester: Pubkey, job: Pubkey) -> Instruction {
    build(acc::CancelJob { requester, job }, ix::CancelJob {})
}

fn offer_ix(wallet: Pubkey, job: Pubkey) -> Instruction {
    build(
        acc::MakeOffer {
            wallet,
            config: config_key(),
            introer: introer_key(&wallet),
            job,
            offer: offer_key(&job, &wallet),
            system_program: anchor_lang::system_program::ID,
        },
        ix::Offer {},
    )
}

fn withdraw_offer_ix(wallet: Pubkey, job: Pubkey) -> Instruction {
    build(
        acc::WithdrawOffer {
            wallet,
            offer: offer_key(&job, &wallet),
            job,
        },
        ix::WithdrawOffer {},
    )
}

fn close_offer_ix(caller: Pubkey, offer: Pubkey, wallet: Pubkey, job: Pubkey) -> Instruction {
    build(
        acc::CloseOffer {
            caller,
            offer,
            wallet,
            job,
        },
        ix::CloseOffer {},
    )
}

fn approve_ix(requester: Pubkey, job: Pubkey, introer_wallet: Pubkey) -> Instruction {
    build(
        acc::Approve {
            requester,
            job,
            offer: offer_key(&job, &introer_wallet),
        },
        ix::Approve { introer_wallet },
    )
}

fn made_ix(wallet: Pubkey, job: Pubkey) -> Instruction {
    build(acc::MarkMade { wallet, job }, ix::MarkMade {})
}

fn confirm_ix(requester: Pubkey, job: Pubkey, wallet: Pubkey) -> Instruction {
    build(
        acc::Confirm {
            requester,
            job,
            introer: introer_key(&wallet),
            wallet,
        },
        ix::Confirm {},
    )
}

fn refund_ix(unconfirmed: bool, caller: Pubkey, job: Pubkey, requester: Pubkey) -> Instruction {
    let accounts = acc::Refund {
        caller,
        job,
        requester,
    };
    if unconfirmed {
        build(accounts, ix::RefundUnconfirmed {})
    } else {
        build(accounts, ix::RefundExpired {})
    }
}

fn admin_ix(admin: Pubkey, data: impl InstructionData) -> Instruction {
    build(
        acc::AdminOnly {
            admin,
            config: config_key(),
        },
        data,
    )
}

fn accept_admin_ix(pending_admin: Pubkey) -> Instruction {
    build(
        acc::AcceptAdmin {
            pending_admin,
            config: config_key(),
        },
        ix::AcceptAdmin {},
    )
}

fn funded(svm: &mut LiteSVM, sol: u64) -> Keypair {
    let key = Keypair::new();
    svm.airdrop(&key.pubkey(), sol * SOL).unwrap();
    key
}

fn read<T: AccountDeserialize>(svm: &LiteSVM, key: &Pubkey) -> T {
    let data = svm.get_account(key).unwrap().data;
    T::try_deserialize(&mut data.as_slice()).unwrap()
}

struct T {
    svm: LiteSVM,
    admin: Keypair,
    /// Jobs and offers that may be live; checked after every tx.
    jobs: Vec<Pubkey>,
    offers: Vec<Pubkey>,
    nonce: u64,
}

impl T {
    fn new() -> Self {
        Self::with_admin(Keypair::new())
    }

    fn with_admin(admin: Keypair) -> Self {
        let mut svm = chain(Some(admin.pubkey()));
        svm.airdrop(&admin.pubkey(), 10 * SOL).unwrap();
        send(&mut svm, &admin, init_config_ix(admin.pubkey())).unwrap();
        Self {
            svm,
            admin,
            jobs: vec![],
            offers: vec![],
            nonce: 0,
        }
    }

    fn user(&mut self, sol: u64) -> Keypair {
        funded(&mut self.svm, sol)
    }

    fn lamports(&self, key: &Pubkey) -> u64 {
        self.svm.get_account(key).map_or(0, |a| a.lamports)
    }

    fn live(&self, key: &Pubkey) -> bool {
        self.svm.get_account(key).is_some_and(|a| a.lamports > 0)
    }

    fn rent(&self, key: &Pubkey) -> u64 {
        let len = self.svm.get_account(key).unwrap().data.len();
        self.svm.minimum_balance_for_rent_exemption(len)
    }

    fn config(&self) -> Config {
        read(&self.svm, &config_key())
    }

    fn board(&self) -> Board {
        let data = self.svm.get_account(&board_key()).unwrap().data;
        bytemuck::pod_read_unaligned::<Board>(&data[8..])
    }

    fn introer(&self, wallet: &Pubkey) -> Introer {
        read(&self.svm, &introer_key(wallet))
    }

    fn job(&self, key: &Pubkey) -> Job {
        read(&self.svm, key)
    }

    fn offer_state(&self, key: &Pubkey) -> Offer {
        read(&self.svm, key)
    }

    fn warp(&mut self, seconds: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp += seconds;
        self.svm.set_sysvar(&clock);
    }

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    /// Books: each live job holds exactly rent + bid, each live offer
    /// exactly rent.
    fn check_books(&mut self) {
        let svm = &self.svm;
        self.jobs
            .retain(|k| svm.get_account(k).is_some_and(|a| a.lamports > 0));
        self.offers
            .retain(|k| svm.get_account(k).is_some_and(|a| a.lamports > 0));
        for key in &self.jobs {
            let job = self.job(key);
            assert_eq!(self.lamports(key), self.rent(key) + job.bid, "job lamports");
        }
        for key in &self.offers {
            assert_eq!(self.lamports(key), self.rent(key), "offer lamports");
        }
    }

    fn run(&mut self, payer: &Keypair, ix: Instruction) -> Result<(), String> {
        let result = send(&mut self.svm, payer, ix);
        self.check_books();
        result
    }

    fn introer_named(&mut self, name: &str) -> Keypair {
        let wallet = self.user(5);
        self.run(&wallet, register_ix(wallet.pubkey(), pad(name)))
            .unwrap();
        wallet
    }

    fn try_post(&mut self, requester: &Keypair, bid: u64) -> Result<Pubkey, String> {
        self.nonce += 1;
        let ix = post_ix(
            requester.pubkey(),
            self.nonce,
            pad("Toly"),
            pad("@alice"),
            bid,
        );
        let key = job_key(&requester.pubkey(), self.nonce);
        self.jobs.push(key);
        self.run(requester, ix)?;
        Ok(key)
    }

    fn post(&mut self, requester: &Keypair, bid: u64) -> Pubkey {
        self.try_post(requester, bid).unwrap()
    }

    fn offer(&mut self, wallet: &Keypair, job: Pubkey) -> Result<(), String> {
        self.offers.push(offer_key(&job, &wallet.pubkey()));
        self.run(wallet, offer_ix(wallet.pubkey(), job))
    }

    fn approve(&mut self, requester: &Keypair, job: Pubkey, wallet: Pubkey) -> Result<(), String> {
        self.run(requester, approve_ix(requester.pubkey(), job, wallet))
    }

    fn made(&mut self, wallet: &Keypair, job: Pubkey) -> Result<(), String> {
        self.run(wallet, made_ix(wallet.pubkey(), job))
    }

    fn confirm(&mut self, requester: &Keypair, job: Pubkey, wallet: Pubkey) -> Result<(), String> {
        self.run(requester, confirm_ix(requester.pubkey(), job, wallet))
    }

    fn refund(
        &mut self,
        unconfirmed: bool,
        caller: &Keypair,
        job: Pubkey,
        requester: Pubkey,
    ) -> Result<(), String> {
        self.run(
            caller,
            refund_ix(unconfirmed, caller.pubkey(), job, requester),
        )
    }

    /// Posted job with one offer, approved.
    fn approved_job(&mut self, bid: u64) -> (Keypair, Keypair, Pubkey) {
        let requester = self.user(200);
        let introer = self.introer_named("Ana");
        let job = self.post(&requester, bid);
        self.offer(&introer, job).unwrap();
        self.approve(&requester, job, introer.pubkey()).unwrap();
        (requester, introer, job)
    }
}

// ---------- config + admin ----------

#[test]
fn init_config_sets_upgrade_authority_as_admin_and_makes_the_board() {
    let t = T::new();
    let config = t.config();
    assert_eq!(config.admin, t.admin.pubkey());
    assert_eq!(config.pending_admin, Pubkey::default());
    assert!(!config.paused);
    let board = t.board();
    assert_eq!((board.head, board.posted), (0, 0));
    assert!(board.jobs.iter().all(|j| *j == Pubkey::default()));
}

#[test]
fn init_config_rejects_non_upgrade_authority() {
    let authority = Keypair::new();
    let mut svm = chain(Some(authority.pubkey()));
    let other = funded(&mut svm, 5);
    fails(
        send(&mut svm, &other, init_config_ix(other.pubkey())),
        "NotUpgradeAuthority",
    );
    assert!(svm.get_account(&config_key()).is_none());
}

#[test]
fn init_config_rejects_everyone_when_program_is_immutable() {
    let mut svm = chain(None);
    let other = funded(&mut svm, 5);
    fails(
        send(&mut svm, &other, init_config_ix(other.pubkey())),
        "NotUpgradeAuthority",
    );
}

#[test]
fn init_config_rejects_fake_program_data() {
    let authority = Keypair::new();
    let mut svm = chain(Some(authority.pubkey()));
    let attacker = funded(&mut svm, 5);
    let fake = Pubkey::new_unique();
    let mut account = svm.get_account(&program_data()).unwrap();
    account.data[13..45].copy_from_slice(attacker.pubkey().as_ref());
    svm.set_account(fake, account).unwrap();
    let mut ix = init_config_ix(attacker.pubkey());
    ix.accounts[4].pubkey = fake;
    fails(send(&mut svm, &attacker, ix), "NotUpgradeAuthority");
}

#[test]
fn init_config_runs_only_once() {
    let mut t = T::new();
    let admin = t.admin.insecure_clone();
    assert!(t.run(&admin, init_config_ix(admin.pubkey())).is_err());
}

#[test]
fn admin_change_is_two_step_and_cancellable() {
    let mut t = T::new();
    let admin = t.admin.insecure_clone();
    let stranger = t.user(1);
    let next = t.user(1);
    let propose = |by: Pubkey, to: Pubkey| admin_ix(by, ix::ProposeAdmin { admin: to });

    fails(
        t.run(&stranger, propose(stranger.pubkey(), stranger.pubkey())),
        "Unauthorized",
    );
    fails(
        t.run(
            &stranger,
            admin_ix(stranger.pubkey(), ix::SetPaused { paused: true }),
        ),
        "Unauthorized",
    );
    fails(
        t.run(
            &stranger,
            admin_ix(stranger.pubkey(), ix::CancelAdminProposal {}),
        ),
        "Unauthorized",
    );
    fails(
        t.run(&admin, propose(admin.pubkey(), Pubkey::default())),
        "NoAdmin",
    );
    // Nobody pending: nobody can accept.
    fails(t.run(&next, accept_admin_ix(next.pubkey())), "Unauthorized");

    t.run(&admin, propose(admin.pubkey(), next.pubkey()))
        .unwrap();
    assert_eq!(t.config().pending_admin, next.pubkey());
    t.run(&admin, admin_ix(admin.pubkey(), ix::CancelAdminProposal {}))
        .unwrap();
    fails(t.run(&next, accept_admin_ix(next.pubkey())), "Unauthorized");

    t.run(&admin, propose(admin.pubkey(), next.pubkey()))
        .unwrap();
    fails(
        t.run(&stranger, accept_admin_ix(stranger.pubkey())),
        "Unauthorized",
    );
    assert_eq!(t.config().admin, admin.pubkey());
    t.run(&next, accept_admin_ix(next.pubkey())).unwrap();
    let config = t.config();
    assert_eq!(config.admin, next.pubkey());
    assert_eq!(config.pending_admin, Pubkey::default());
    fails(
        t.run(
            &admin,
            admin_ix(admin.pubkey(), ix::SetPaused { paused: true }),
        ),
        "Unauthorized",
    );
    t.run(
        &next,
        admin_ix(next.pubkey(), ix::SetPaused { paused: true }),
    )
    .unwrap();
    assert!(t.config().paused);
}

#[test]
fn admin_keeps_working_after_program_is_made_immutable() {
    let mut t = T::new();
    let key = program_data();
    let mut account = t.svm.get_account(&key).unwrap();
    account.data[12] = 0;
    t.svm.set_account(key, account).unwrap();
    let admin = t.admin.insecure_clone();
    t.run(
        &admin,
        admin_ix(admin.pubkey(), ix::SetPaused { paused: true }),
    )
    .unwrap();
    assert!(t.config().paused);
}

// ---------- introer ----------

#[test]
fn register_and_update_introer() {
    let mut t = T::new();
    let wallet = t.introer_named("Ana");
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.wallet, wallet.pubkey());
    assert_eq!(&introer.badge_id, b"BP26-001");
    assert_eq!(introer.name, pad("Ana"));
    assert_eq!((introer.jobs_done, introer.earned), (0, 0));
    assert_eq!(introer.created_at, t.now());
    // Once only.
    assert!(t
        .run(&wallet, register_ix(wallet.pubkey(), pad("B")))
        .is_err());

    let update = |signer: Pubkey, name: Text| {
        build(
            acc::UpdateIntroer {
                wallet: signer,
                introer: introer_key(&wallet.pubkey()),
            },
            ix::UpdateIntroer {
                badge_id: *b"BP26-002",
                name,
            },
        )
    };
    let stranger = t.user(1);
    assert!(t
        .run(&stranger, update(stranger.pubkey(), pad("X")))
        .is_err());
    fails(
        t.run(&wallet, update(wallet.pubkey(), [0; TEXT_LEN])),
        "BadText",
    );
    t.run(&wallet, update(wallet.pubkey(), pad("Ana B")))
        .unwrap();
    let introer = t.introer(&wallet.pubkey());
    assert_eq!(introer.name, pad("Ana B"));
    assert_eq!(&introer.badge_id, b"BP26-002");
}

#[test]
fn register_checks_the_name() {
    let mut t = T::new();
    let wallet = t.user(1);
    fails(
        t.run(&wallet, register_ix(wallet.pubkey(), [0; TEXT_LEN])),
        "BadText",
    );
    let mut bad = pad("ab");
    bad[5] = b'x';
    fails(t.run(&wallet, register_ix(wallet.pubkey(), bad)), "BadText");
    let mut bad = pad("ab");
    bad[0] = 0xff;
    fails(t.run(&wallet, register_ix(wallet.pubkey(), bad)), "BadText");
    t.run(&wallet, register_ix(wallet.pubkey(), pad(&"é".repeat(16))))
        .unwrap();
}

// ---------- happy path ----------

#[test]
fn happy_path_pays_the_approved_introer_and_returns_rent() {
    let mut t = T::new();
    let requester = t.user(20);
    let ana = t.introer_named("Ana");
    let bo = t.introer_named("Bo");
    let before = t.lamports(&requester.pubkey());
    let job = t.post(&requester, 2 * SOL);

    let stored = t.job(&job);
    assert_eq!(stored.requester, requester.pubkey());
    assert_eq!(stored.nonce, t.nonce);
    assert_eq!(stored.serial, 0);
    assert_eq!(stored.bid, 2 * SOL);
    assert_eq!(stored.status, STATUS_OPEN);
    assert_eq!(stored.created_at, t.now());
    assert_eq!(stored.approved, Pubkey::default());
    assert_eq!((stored.who, stored.company), (pad("Toly"), pad("Solana")));
    assert_eq!(stored.telegram, pad("@alice"));
    let board = t.board();
    assert_eq!((board.head, board.posted), (1, 1));
    assert_eq!(board.jobs[0], job);

    t.offer(&ana, job).unwrap();
    t.offer(&bo, job).unwrap();
    let stored = t.job(&job);
    assert_eq!(stored.offer_count, 2);
    assert_eq!(stored.offers_head, 2);
    assert_eq!(&stored.offers[..2], &[ana.pubkey(), bo.pubkey()]);
    let offer = t.offer_state(&offer_key(&job, &bo.pubkey()));
    assert_eq!((offer.job, offer.introer), (job, bo.pubkey()));
    assert_eq!(offer.job_serial, 0);

    t.warp(60);
    t.approve(&requester, job, bo.pubkey()).unwrap();
    let stored = t.job(&job);
    assert_eq!(stored.status, STATUS_APPROVED);
    assert_eq!(stored.approved, bo.pubkey());
    assert_eq!(stored.approved_at, t.now());

    // Only the approved introer marks it made.
    fails(t.made(&ana, job), "Unauthorized");
    t.warp(60);
    t.made(&bo, job).unwrap();
    let stored = t.job(&job);
    assert_eq!(stored.status, STATUS_MADE);
    assert_eq!(stored.made_at, t.now());

    let bo_before = t.lamports(&bo.pubkey());
    t.confirm(&requester, job, bo.pubkey()).unwrap();
    assert!(!t.live(&job));
    assert_eq!(t.lamports(&bo.pubkey()), bo_before + 2 * SOL);
    // Requester is down only the bid and 3 tx fees: rent came back.
    assert_eq!(t.lamports(&requester.pubkey()), before - 2 * SOL - 3 * FEE);
    let stats = t.introer(&bo.pubkey());
    assert_eq!((stats.jobs_done, stats.earned), (1, 2 * SOL));
    assert_eq!(t.introer(&ana.pubkey()).jobs_done, 0);

    // Offers close afterwards, rent to each introer.
    for wallet in [&ana, &bo] {
        let offer = offer_key(&job, &wallet.pubkey());
        let rent = t.lamports(&offer);
        let before = t.lamports(&wallet.pubkey());
        let anyone = t.user(1);
        t.run(
            &anyone,
            close_offer_ix(anyone.pubkey(), offer, wallet.pubkey(), job),
        )
        .unwrap();
        assert_eq!(t.lamports(&wallet.pubkey()), before + rent);
    }
}

#[test]
fn confirm_works_from_approved_but_not_open() {
    let mut t = T::new();
    let requester = t.user(20);
    let ana = t.introer_named("Ana");
    let job = t.post(&requester, SOL);
    t.offer(&ana, job).unwrap();
    // Open: approved is the default key, so there's no introer to pay.
    assert!(t.confirm(&requester, job, ana.pubkey()).is_err());
    t.approve(&requester, job, ana.pubkey()).unwrap();
    t.confirm(&requester, job, ana.pubkey()).unwrap();
    assert_eq!(t.introer(&ana.pubkey()).jobs_done, 1);
}

// ---------- post / cancel ----------

#[test]
fn post_job_checks_bid_text_and_pause() {
    let mut t = T::new();
    let requester = t.user(300);
    let r = requester.pubkey();
    fails(t.try_post(&requester, MIN_BID - 1).map(|_| ()), "BidTooLow");
    fails(
        t.try_post(&requester, MAX_BID + 1).map(|_| ()),
        "BidTooHigh",
    );
    t.post(&requester, MIN_BID);
    t.post(&requester, MAX_BID);
    for (who, telegram) in [
        ([0; TEXT_LEN], pad("@a")),
        (pad("Toly"), [0; TEXT_LEN]),
        (
            {
                let mut bad = pad("Toly");
                bad[TEXT_LEN - 1] = b'x';
                bad
            },
            pad("@a"),
        ),
        (pad("Toly"), {
            let mut bad = pad("@a");
            bad[1] = 0xc3;
            bad
        }),
    ] {
        fails(
            t.run(&requester, post_ix(r, 900, who, telegram, SOL)),
            "BadText",
        );
    }
    let mut ix = post_ix(r, 900, pad("Toly"), pad("@a"), SOL);
    ix.data = ix::PostJob {
        nonce: 900,
        who: pad("Toly"),
        company: [0; TEXT_LEN],
        telegram: pad("@a"),
        bid: SOL,
    }
    .data();
    fails(t.run(&requester, ix), "BadText");

    let admin = t.admin.insecure_clone();
    t.run(
        &admin,
        admin_ix(admin.pubkey(), ix::SetPaused { paused: true }),
    )
    .unwrap();
    fails(t.try_post(&requester, SOL).map(|_| ()), "Paused");
}

#[test]
fn post_job_seeds_bind_requester_and_nonce() {
    let mut t = T::new();
    let requester = t.user(5);
    let mut ix = post_ix(requester.pubkey(), 1, pad("Toly"), pad("@a"), SOL);
    ix.accounts[3].pubkey = job_key(&requester.pubkey(), 2);
    assert!(t.run(&requester, ix).is_err());
    // Same nonce twice: the second post fails.
    t.run(
        &requester,
        post_ix(requester.pubkey(), 1, pad("A"), pad("@a"), SOL),
    )
    .unwrap();
    t.jobs.push(job_key(&requester.pubkey(), 1));
    assert!(t
        .run(
            &requester,
            post_ix(requester.pubkey(), 1, pad("B"), pad("@a"), SOL)
        )
        .is_err());
}

#[test]
fn board_ring_wraps_around() {
    let mut t = T::new();
    let requester = t.user(10);
    let mut jobs = vec![];
    for _ in 0..BOARD_LEN + 2 {
        jobs.push(t.post(&requester, MIN_BID));
    }
    let board = t.board();
    assert_eq!(usize::from(board.head), 2);
    assert_eq!(board.posted, (BOARD_LEN + 2) as u64);
    assert_eq!(board.jobs[0], jobs[BOARD_LEN]);
    assert_eq!(board.jobs[1], jobs[BOARD_LEN + 1]);
    assert_eq!(board.jobs[2], jobs[2]);
}

#[test]
fn cancel_job_only_by_requester_and_only_open() {
    let mut t = T::new();
    let requester = t.user(10);
    let stranger = t.user(1);
    let job = t.post(&requester, SOL);
    // A stranger can't cancel, even naming the requester's job.
    assert!(t.run(&stranger, cancel_ix(stranger.pubkey(), job)).is_err());
    let before = t.lamports(&requester.pubkey());
    let held = t.lamports(&job);
    t.run(&requester, cancel_ix(requester.pubkey(), job))
        .unwrap();
    assert_eq!(t.lamports(&requester.pubkey()), before + held - FEE);

    let (requester, _, job) = t.approved_job(SOL);
    fails(
        t.run(&requester, cancel_ix(requester.pubkey(), job)),
        "BadStatus",
    );
}

// ---------- offers ----------

#[test]
fn offer_rules() {
    let mut t = T::new();
    let requester = t.user(10);
    let job = t.post(&requester, SOL);
    // Not registered.
    let nobody = t.user(1);
    assert!(t.offer(&nobody, job).is_err());
    // Requester can't offer, even when registered.
    t.run(&requester, register_ix(requester.pubkey(), pad("Me")))
        .unwrap();
    fails(t.offer(&requester, job), "SelfOffer");
    // One offer per introer.
    let ana = t.introer_named("Ana");
    t.offer(&ana, job).unwrap();
    assert!(t.offer(&ana, job).is_err());
    assert_eq!(t.job(&job).offer_count, 1);
    // Paused blocks offers.
    let admin = t.admin.insecure_clone();
    t.run(
        &admin,
        admin_ix(admin.pubkey(), ix::SetPaused { paused: true }),
    )
    .unwrap();
    let bo = t.introer_named("Bo");
    fails(t.offer(&bo, job), "Paused");
    t.run(
        &admin,
        admin_ix(admin.pubkey(), ix::SetPaused { paused: false }),
    )
    .unwrap();
    // Not open any more.
    t.approve(&requester, job, ana.pubkey()).unwrap();
    fails(t.offer(&bo, job), "BadStatus");
}

#[test]
fn offers_are_unlimited_and_the_ring_keeps_the_newest() {
    let mut t = T::new();
    let requester = t.user(10);
    let job = t.post(&requester, SOL);
    let mut wallets = vec![];
    for i in 0..OFFER_RING + 3 {
        let wallet = t.introer_named(&format!("I{i}"));
        t.offer(&wallet, job).unwrap();
        wallets.push(wallet.pubkey());
    }
    let stored = t.job(&job);
    assert_eq!(usize::from(stored.offer_count), OFFER_RING + 3);
    assert_eq!(usize::from(stored.offers_head), 3);
    assert_eq!(stored.offers[0], wallets[OFFER_RING]);
    assert_eq!(stored.offers[3], wallets[3]);
    // An offer that fell out of the ring can still be approved.
    t.approve(&requester, job, wallets[0]).unwrap();
}

#[test]
fn withdraw_offer_rules() {
    let mut t = T::new();
    let requester = t.user(10);
    let ana = t.introer_named("Ana");
    let bo = t.introer_named("Bo");
    let job = t.post(&requester, SOL);
    t.offer(&ana, job).unwrap();
    t.offer(&bo, job).unwrap();
    // Only the offering introer can withdraw.
    let mut ix = withdraw_offer_ix(bo.pubkey(), job);
    ix.accounts[1].pubkey = offer_key(&job, &ana.pubkey());
    assert!(t.run(&bo, ix).is_err());
    // Wrong job account.
    let other = t.post(&requester, SOL);
    let mut ix = withdraw_offer_ix(ana.pubkey(), job);
    ix.accounts[2].pubkey = other;
    fails(t.run(&ana, ix), "WrongJob");

    t.approve(&requester, job, ana.pubkey()).unwrap();
    // The approved offer is locked while the job is live; others are free.
    fails(
        t.run(&ana, withdraw_offer_ix(ana.pubkey(), job)),
        "OfferInUse",
    );
    let rent = t.lamports(&offer_key(&job, &bo.pubkey()));
    let before = t.lamports(&bo.pubkey());
    t.run(&bo, withdraw_offer_ix(bo.pubkey(), job)).unwrap();
    assert_eq!(t.lamports(&bo.pubkey()), before + rent - FEE);
    // The withdrawn offer is gone.
    assert!(t.approve(&requester, job, bo.pubkey()).is_err());
    t.made(&ana, job).unwrap();
    fails(
        t.run(&ana, withdraw_offer_ix(ana.pubkey(), job)),
        "OfferInUse",
    );
    t.confirm(&requester, job, ana.pubkey()).unwrap();
    t.run(&ana, withdraw_offer_ix(ana.pubkey(), job)).unwrap();
}

#[test]
fn withdrawn_offer_cannot_be_approved() {
    let mut t = T::new();
    let requester = t.user(10);
    let ana = t.introer_named("Ana");
    let job = t.post(&requester, SOL);
    t.offer(&ana, job).unwrap();
    t.run(&ana, withdraw_offer_ix(ana.pubkey(), job)).unwrap();
    assert!(t.approve(&requester, job, ana.pubkey()).is_err());
    // Offering again works.
    t.offer(&ana, job).unwrap();
    t.approve(&requester, job, ana.pubkey()).unwrap();
}

#[test]
fn close_offer_only_once_the_job_is_gone() {
    let mut t = T::new();
    let requester = t.user(10);
    let ana = t.introer_named("Ana");
    let job = t.post(&requester, SOL);
    t.offer(&ana, job).unwrap();
    let offer = offer_key(&job, &ana.pubkey());
    let anyone = t.user(1);
    fails(
        t.run(
            &anyone,
            close_offer_ix(anyone.pubkey(), offer, ana.pubkey(), job),
        ),
        "JobLive",
    );
    t.run(&requester, cancel_ix(requester.pubkey(), job))
        .unwrap();
    // Rent must go to the introer.
    fails(
        t.run(
            &anyone,
            close_offer_ix(anyone.pubkey(), offer, anyone.pubkey(), job),
        ),
        "WrongWallet",
    );
    let other = t.post(&requester, SOL);
    fails(
        t.run(
            &anyone,
            close_offer_ix(anyone.pubkey(), offer, ana.pubkey(), other),
        ),
        "WrongJob",
    );
    let before = t.lamports(&ana.pubkey());
    let rent = t.lamports(&offer);
    t.run(
        &anyone,
        close_offer_ix(anyone.pubkey(), offer, ana.pubkey(), job),
    )
    .unwrap();
    assert_eq!(t.lamports(&ana.pubkey()), before + rent);
    assert!(t
        .run(
            &anyone,
            close_offer_ix(anyone.pubkey(), offer, ana.pubkey(), job)
        )
        .is_err());
}

#[test]
fn reposting_at_the_same_address_does_not_revive_old_offers() {
    let mut t = T::new();
    let requester = t.user(10);
    let ana = t.introer_named("Ana");
    let r = requester.pubkey();
    t.run(&requester, post_ix(r, 7, pad("A"), pad("@a"), SOL))
        .unwrap();
    let job = job_key(&r, 7);
    t.jobs.push(job);
    t.offer(&ana, job).unwrap();
    t.run(&requester, cancel_ix(r, job)).unwrap();
    // Same nonce again: a new post at the same address.
    t.run(&requester, post_ix(r, 7, pad("B"), pad("@a"), SOL))
        .unwrap();
    t.jobs.push(job);
    assert_eq!(t.job(&job).serial, 1);
    // The old offer can't be approved on the new post...
    fails(t.approve(&requester, job, ana.pubkey()), "StaleOffer");
    // ...and anyone can clear it, after which Ana can offer again.
    let offer = offer_key(&job, &ana.pubkey());
    let anyone = t.user(1);
    t.run(
        &anyone,
        close_offer_ix(anyone.pubkey(), offer, ana.pubkey(), job),
    )
    .unwrap();
    t.offer(&ana, job).unwrap();
    t.approve(&requester, job, ana.pubkey()).unwrap();
}

// ---------- approve / made / confirm ----------

#[test]
fn approve_needs_the_requester_an_offer_and_open() {
    let mut t = T::new();
    let requester = t.user(10);
    let ana = t.introer_named("Ana");
    let bo = t.introer_named("Bo");
    let job = t.post(&requester, SOL);
    t.offer(&ana, job).unwrap();
    // No offer from Bo.
    assert!(t.approve(&requester, job, bo.pubkey()).is_err());
    // An offer on another job doesn't count.
    let other = t.post(&requester, SOL);
    t.offer(&bo, other).unwrap();
    let mut ix = approve_ix(requester.pubkey(), job, bo.pubkey());
    ix.accounts[2].pubkey = offer_key(&other, &bo.pubkey());
    assert!(t.run(&requester, ix).is_err());
    // Only the requester approves.
    let stranger = t.user(1);
    assert!(t
        .run(&stranger, approve_ix(stranger.pubkey(), job, ana.pubkey()))
        .is_err());
    t.approve(&requester, job, ana.pubkey()).unwrap();
    fails(t.approve(&requester, job, ana.pubkey()), "BadStatus");
}

#[test]
fn mark_made_only_by_the_approved_within_the_work_window() {
    let mut t = T::new();
    let (requester, ana, job) = t.approved_job(SOL);
    let stranger = t.user(1);
    fails(t.made(&stranger, job), "Unauthorized");
    t.warp(WORK_WINDOW + 1);
    fails(t.made(&ana, job), "WorkExpired");
    // Exactly at the deadline works.
    let (_, ana, job) = t.approved_job(SOL);
    t.warp(WORK_WINDOW);
    t.made(&ana, job).unwrap();
    fails(t.made(&ana, job), "BadStatus");
    // Not before approval.
    let open = t.post(&requester, SOL);
    fails(t.made(&ana, open), "BadStatus");
}

#[test]
fn payout_goes_only_to_the_approved_introer() {
    let mut t = T::new();
    let (requester, ana, job) = t.approved_job(SOL);
    let thief = t.introer_named("Thief");
    let other = t.post(&requester, SOL);
    t.offer(&thief, other).unwrap();
    // Thief's wallet with the real introer PDA.
    let mut ix = confirm_ix(requester.pubkey(), job, ana.pubkey());
    ix.accounts[3].pubkey = thief.pubkey();
    fails(t.run(&requester, ix), "WrongWallet");
    // Thief's wallet and PDA.
    assert!(t.confirm(&requester, job, thief.pubkey()).is_err());
    // Someone else can't confirm.
    let ix = confirm_ix(thief.pubkey(), job, ana.pubkey());
    assert!(t.run(&thief, ix).is_err());
    let before = t.lamports(&ana.pubkey());
    t.confirm(&requester, job, ana.pubkey()).unwrap();
    assert_eq!(t.lamports(&ana.pubkey()), before + SOL);
    assert_eq!(t.introer(&thief.pubkey()).jobs_done, 0);
    // Double settle is impossible.
    assert!(t.confirm(&requester, job, ana.pubkey()).is_err());
    assert_eq!(t.introer(&ana.pubkey()).jobs_done, 1);
}

#[test]
fn paused_never_blocks_payouts_or_refunds() {
    let mut t = T::new();
    let (requester, ana, to_confirm) = t.approved_job(SOL);
    let to_cancel = t.post(&requester, SOL);
    let (requester2, _, to_refund) = t.approved_job(SOL);
    let admin = t.admin.insecure_clone();
    t.run(
        &admin,
        admin_ix(admin.pubkey(), ix::SetPaused { paused: true }),
    )
    .unwrap();
    t.run(&requester, cancel_ix(requester.pubkey(), to_cancel))
        .unwrap();
    t.made(&ana, to_confirm).unwrap();
    t.confirm(&requester, to_confirm, ana.pubkey()).unwrap();
    t.warp(WORK_WINDOW + 1);
    t.refund(false, &requester2, to_refund, requester2.pubkey())
        .unwrap();
    assert!(t.jobs.is_empty());
}

// ---------- refunds ----------

#[test]
fn refund_expired_timing() {
    let mut t = T::new();
    let (requester, _ana, job) = t.approved_job(SOL);
    let r = requester.pubkey();
    let anyone = t.user(1);
    t.warp(WORK_WINDOW);
    fails(t.refund(false, &requester, job, r), "NotExpired");
    t.warp(1);
    // Others wait CONFIRM_WINDOW more.
    fails(t.refund(false, &anyone, job, r), "NotExpired");
    // The refund can't be pointed at another wallet.
    assert!(t.refund(false, &anyone, job, anyone.pubkey()).is_err());
    let before = t.lamports(&r);
    let held = t.lamports(&job);
    t.refund(false, &requester, job, r).unwrap();
    assert_eq!(t.lamports(&r), before + held - FEE);
    assert!(t.refund(false, &requester, job, r).is_err());
}

#[test]
fn others_refund_expired_after_the_grace_and_late_confirm_wins_before() {
    let mut t = T::new();
    let (requester, ana, job) = t.approved_job(SOL);
    let r = requester.pubkey();
    let anyone = t.user(1);
    t.warp(WORK_WINDOW + CONFIRM_WINDOW);
    fails(t.refund(false, &anyone, job, r), "NotExpired");
    // Inside the grace the requester can still confirm.
    t.confirm(&requester, job, ana.pubkey()).unwrap();
    assert_eq!(t.introer(&ana.pubkey()).jobs_done, 1);

    let (requester, _, job) = t.approved_job(SOL);
    let r = requester.pubkey();
    t.warp(WORK_WINDOW + CONFIRM_WINDOW + 1);
    let before = t.lamports(&r);
    let held = t.lamports(&job);
    t.refund(false, &anyone, job, r).unwrap();
    assert_eq!(t.lamports(&r), before + held);
}

#[test]
fn refund_unconfirmed_timing() {
    let mut t = T::new();
    let (requester, ana, job) = t.approved_job(SOL);
    let r = requester.pubkey();
    let anyone = t.user(1);
    fails(t.refund(true, &requester, job, r), "BadStatus");
    t.made(&ana, job).unwrap();
    fails(t.refund(false, &requester, job, r), "BadStatus");
    t.warp(CONFIRM_WINDOW);
    fails(t.refund(true, &requester, job, r), "NotExpired");
    t.warp(1);
    fails(t.refund(true, &anyone, job, r), "NotExpired");
    t.warp(CONFIRM_WINDOW);
    let before = t.lamports(&r);
    let held = t.lamports(&job);
    t.refund(true, &anyone, job, r).unwrap();
    assert_eq!(t.lamports(&r), before + held);
    assert_eq!(t.introer(&ana.pubkey()).jobs_done, 0);
}

#[test]
fn refunds_need_the_right_state() {
    let mut t = T::new();
    let requester = t.user(10);
    let r = requester.pubkey();
    let job = t.post(&requester, SOL);
    t.warp(WORK_WINDOW * 3);
    fails(t.refund(false, &requester, job, r), "BadStatus");
    fails(t.refund(true, &requester, job, r), "BadStatus");
}

// ---------- lamport accounting ----------

#[test]
fn extra_lamports_sent_to_a_job_go_back_to_requester() {
    let mut t = T::new();
    let (requester, ana, job) = t.approved_job(SOL);
    let donor = t.user(2);
    let ix = anchor_lang::solana_program::system_instruction::transfer(&donor.pubkey(), &job, SOL);
    send(&mut t.svm, &donor, ix).unwrap();
    t.jobs.clear();
    let held = t.lamports(&job);
    let ana_before = t.lamports(&ana.pubkey());
    let before = t.lamports(&requester.pubkey());
    t.confirm(&requester, job, ana.pubkey()).unwrap();
    assert_eq!(t.lamports(&ana.pubkey()), ana_before + SOL);
    assert_eq!(t.lamports(&requester.pubkey()), before + held - SOL - FEE);
}

#[test]
fn constants_match_spec() {
    assert_eq!(MAX_BID, 100 * SOL);
    assert_eq!(MIN_BID, 10_000_000);
    assert_eq!(WORK_WINDOW, 7 * 86_400);
    assert_eq!(CONFIRM_WINDOW, 72 * 3600);
    assert_eq!((BOARD_LEN, OFFER_RING, TEXT_LEN), (64, 16, 32));
    assert_eq!((STATUS_OPEN, STATUS_APPROVED, STATUS_MADE), (0, 1, 2));
}

// ---------- fixed layouts + fixtures ----------

fn u64_at(data: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(data[at..at + 8].try_into().unwrap())
}

/// Byte offsets documented in docs/spec-v2.md.
#[test]
fn account_layouts_have_fixed_offsets() {
    let mut t = T::new();
    let (requester, ana, job) = t.approved_job(2 * SOL);

    let data = t.svm.get_account(&config_key()).unwrap().data;
    assert_eq!(data.len(), 74);
    assert_eq!(&data[8..40], t.admin.pubkey().as_ref());
    assert!(data[40..72].iter().all(|b| *b == 0));
    assert_eq!((data[72], data[73]), (0, t.config().bump));

    let data = t.svm.get_account(&board_key()).unwrap().data;
    assert_eq!(data.len(), 24 + 32 * BOARD_LEN);
    assert_eq!((data[8], data[9]), (1, t.board().bump));
    assert_eq!(u64_at(&data, 16), 1);
    assert_eq!(&data[24..56], job.as_ref());

    let data = t.svm.get_account(&introer_key(&ana.pubkey())).unwrap().data;
    assert_eq!(data.len(), 101);
    assert_eq!(&data[8..40], ana.pubkey().as_ref());
    assert_eq!(&data[40..48], b"BP26-001");
    assert_eq!(&data[48..80], &pad("Ana"));
    assert_eq!(&data[80..84], &0u32.to_le_bytes());
    assert_eq!(u64_at(&data, 84), 0);
    assert_eq!(
        u64_at(&data, 92) as i64,
        t.introer(&ana.pubkey()).created_at
    );
    assert_eq!(data[100], t.introer(&ana.pubkey()).bump);

    let state = t.job(&job);
    let data = t.svm.get_account(&job).unwrap().data;
    assert_eq!(data.len(), 733);
    assert_eq!(&data[8..40], requester.pubkey().as_ref());
    assert_eq!(u64_at(&data, 40), state.nonce);
    assert_eq!(u64_at(&data, 48), 0); // serial
    assert_eq!(u64_at(&data, 56), 2 * SOL);
    assert_eq!(data[64], STATUS_APPROVED);
    assert_eq!(u64_at(&data, 65) as i64, state.created_at);
    assert_eq!(u64_at(&data, 73) as i64, state.approved_at);
    assert_eq!(u64_at(&data, 81), 0); // made_at
    assert_eq!(&data[89..121], ana.pubkey().as_ref());
    assert_eq!(&data[121..123], &1u16.to_le_bytes());
    assert_eq!(&data[123..155], ana.pubkey().as_ref()); // offers[0]
    assert!(data[155..635].iter().all(|b| *b == 0));
    assert_eq!(data[635], 1); // offers_head
    assert_eq!(&data[636..668], &pad("Toly"));
    assert_eq!(&data[668..700], &pad("Solana"));
    assert_eq!(&data[700..732], &pad("@alice"));
    assert_eq!(data[732], state.bump);

    let offer = offer_key(&job, &ana.pubkey());
    let data = t.svm.get_account(&offer).unwrap().data;
    assert_eq!(data.len(), 89);
    assert_eq!(&data[8..40], job.as_ref());
    assert_eq!(&data[40..72], ana.pubkey().as_ref());
    assert_eq!(u64_at(&data, 72), 0); // job_serial
    assert_eq!(u64_at(&data, 80) as i64, t.offer_state(&offer).created_at);
    assert_eq!(data[88], t.offer_state(&offer).bump);
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::new(), |mut out, b| {
        write!(out, "{b:02x}").unwrap();
        out
    })
}

fn fixture(name: &str, ix: &Instruction) -> String {
    let accounts: Vec<String> = ix
        .accounts
        .iter()
        .map(|m| {
            format!(
                "    {{ \"pubkey\": \"{}\", \"signer\": {}, \"writable\": {} }}",
                m.pubkey, m.is_signer, m.is_writable
            )
        })
        .collect();
    format!(
        "{{\n  \"name\": \"{name}\",\n  \"program_id\": \"{}\",\n  \"accounts\": [\n{}\n  ],\n  \"data_hex\": \"{}\"\n}}\n",
        ix.program_id,
        accounts.join(",\n"),
        hex(&ix.data)
    )
}

/// Writes one instruction per file to `tests/fixtures/`, built from fixed
/// keys, after checking each one runs. Clients compare their encoders with
/// these. Account dumps go to `tests/fixtures/accounts.json`.
#[test]
fn write_instruction_fixtures() {
    let key = |n: u8| Keypair::new_from_array([n; 32]);
    let (admin, introer, requester, other) = (key(1), key(2), key(3), key(4));
    let mut t = T::with_admin(admin.insecure_clone());
    let mut clock: Clock = t.svm.get_sysvar();
    clock.unix_timestamp = 1_790_000_000;
    t.svm.set_sysvar(&clock);
    for k in [&introer, &requester, &other] {
        t.svm.airdrop(&k.pubkey(), 30 * SOL).unwrap();
    }
    let (i, r) = (introer.pubkey(), requester.pubkey());
    let job = |nonce: u64| job_key(&r, nonce);
    // init_config already ran in `with_admin`; record the same instruction.
    let mut out: Vec<(&str, Instruction)> = vec![("init_config", init_config_ix(admin.pubkey()))];
    let mut go = |t: &mut T, name: &'static str, payer: &Keypair, ix: Instruction| {
        t.run(payer, ix.clone()).unwrap();
        out.push((name, ix));
    };
    let post = |t: &mut T, nonce: u64| {
        t.jobs.push(job(nonce));
        post_ix(r, nonce, pad("Toly"), pad("@alice"), SOL)
    };

    go(
        &mut t,
        "register_introer",
        &introer,
        register_ix(i, pad("Ana")),
    );
    let ix = build(
        acc::UpdateIntroer {
            wallet: i,
            introer: introer_key(&i),
        },
        ix::UpdateIntroer {
            badge_id: *b"BP26-001",
            name: pad("Ana B"),
        },
    );
    go(&mut t, "update_introer", &introer, ix);
    let ix = post(&mut t, 1);
    go(&mut t, "post_job", &requester, ix);
    t.offers.push(offer_key(&job(1), &i));
    go(&mut t, "offer", &introer, offer_ix(i, job(1)));
    go(&mut t, "approve", &requester, approve_ix(r, job(1), i));
    go(&mut t, "mark_made", &introer, made_ix(i, job(1)));
    go(&mut t, "confirm", &requester, confirm_ix(r, job(1), i));
    go(
        &mut t,
        "close_offer",
        &other,
        close_offer_ix(other.pubkey(), offer_key(&job(1), &i), i, job(1)),
    );
    let ix = post(&mut t, 2);
    t.run(&requester, ix).unwrap();
    t.offers.push(offer_key(&job(2), &i));
    t.run(&introer, offer_ix(i, job(2))).unwrap();
    go(
        &mut t,
        "withdraw_offer",
        &introer,
        withdraw_offer_ix(i, job(2)),
    );
    go(&mut t, "cancel_job", &requester, cancel_ix(r, job(2)));
    for nonce in [3, 4] {
        let ix = post(&mut t, nonce);
        t.run(&requester, ix).unwrap();
        t.offers.push(offer_key(&job(nonce), &i));
        t.run(&introer, offer_ix(i, job(nonce))).unwrap();
        t.run(&requester, approve_ix(r, job(nonce), i)).unwrap();
    }
    t.run(&introer, made_ix(i, job(4))).unwrap();
    t.warp(WORK_WINDOW + 1);
    go(
        &mut t,
        "refund_expired",
        &requester,
        refund_ix(false, r, job(3), r),
    );
    go(
        &mut t,
        "refund_unconfirmed",
        &requester,
        refund_ix(true, r, job(4), r),
    );
    // A live job with an offer, for the account dump.
    let ix = post(&mut t, 5);
    t.run(&requester, ix).unwrap();
    t.offers.push(offer_key(&job(5), &i));
    t.run(&introer, offer_ix(i, job(5))).unwrap();
    go(
        &mut t,
        "set_paused",
        &admin,
        admin_ix(admin.pubkey(), ix::SetPaused { paused: false }),
    );
    go(
        &mut t,
        "propose_admin",
        &admin,
        admin_ix(admin.pubkey(), ix::ProposeAdmin { admin: i }),
    );
    go(
        &mut t,
        "cancel_admin_proposal",
        &admin,
        admin_ix(admin.pubkey(), ix::CancelAdminProposal {}),
    );
    t.run(
        &admin,
        admin_ix(admin.pubkey(), ix::ProposeAdmin { admin: i }),
    )
    .unwrap();
    go(&mut t, "accept_admin", &introer, accept_admin_ix(i));

    let dir = std::path::Path::new("fixtures");
    if dir.exists() {
        std::fs::remove_dir_all(dir).unwrap();
    }
    std::fs::create_dir_all(dir).unwrap();
    for (name, ix) in &out {
        std::fs::write(dir.join(format!("{name}.json")), fixture(name, ix)).unwrap();
    }
    let dump = |key: Pubkey| {
        let data = t.svm.get_account(&key).unwrap().data;
        format!(
            "{{ \"pubkey\": \"{key}\", \"data_hex\": \"{}\" }}",
            hex(&data)
        )
    };
    let accounts = format!(
        "{{\n  \"config\": {},\n  \"board\": {},\n  \"introer\": {},\n  \"job\": {},\n  \"offer\": {}\n}}\n",
        dump(config_key()),
        dump(board_key()),
        dump(introer_key(&i)),
        dump(job(5)),
        dump(offer_key(&job(5), &i)),
    );
    std::fs::write(dir.join("accounts.json"), accounts).unwrap();
}
