//! Intro Bot escrow (v2, requester-first): a requester posts a job with a
//! SOL bid, introers offer, the requester approves one, and the bid is paid
//! to that introer once the requester confirms. See `docs/spec-v2.md`.
#![allow(unexpected_cfgs, reason = "anchor macros emit cfgs")]

use anchor_lang::prelude::*;
use anchor_lang::system_program;
pub use solana_native_token::LAMPORTS_PER_SOL;

declare_id!("GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC");

pub const MAX_BID: u64 = 100 * LAMPORTS_PER_SOL;
pub const MIN_BID: u64 = LAMPORTS_PER_SOL / 100;
/// Time the approved introer has to mark the intro made.
pub const WORK_WINDOW: i64 = 7 * 24 * 60 * 60;
/// Time the requester has to confirm a made intro. Also the extra wait
/// before anyone but the requester can trigger a refund.
pub const CONFIRM_WINDOW: i64 = 72 * 60 * 60;
pub const TEXT_LEN: usize = 32;
pub const BOARD_LEN: usize = 64;
pub const OFFER_RING: usize = 16;

pub const STATUS_OPEN: u8 = 0;
pub const STATUS_APPROVED: u8 = 1;
pub const STATUS_MADE: u8 = 2;

/// `Refunded.reason` values.
pub const REFUND_CANCELLED: u8 = 0;
pub const REFUND_EXPIRED: u8 = 1;
pub const REFUND_UNCONFIRMED: u8 = 2;

#[program]
pub mod intro_escrow {
    use super::*;

    /// Creates the config and the board. Only the program's upgrade
    /// authority can call it; the signer becomes the admin.
    pub fn init_config(ctx: Context<InitConfig>) -> Result<()> {
        ctx.accounts.config.set_inner(Config {
            admin: ctx.accounts.authority.key(),
            pending_admin: Pubkey::default(),
            paused: false,
            bump: ctx.bumps.config,
        });
        let mut board = ctx.accounts.board.load_init()?;
        board.bump = ctx.bumps.board;
        Ok(())
    }

    /// Step 1 of an admin change: names the next admin, who must accept.
    pub fn propose_admin(ctx: Context<AdminOnly>, admin: Pubkey) -> Result<()> {
        require_keys_neq!(admin, Pubkey::default(), EscrowError::NoAdmin);
        ctx.accounts.config.pending_admin = admin;
        emit!(AdminProposed { admin });
        Ok(())
    }

    /// Step 2: the proposed admin signs to take over.
    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.admin = config.pending_admin;
        config.pending_admin = Pubkey::default();
        emit!(AdminAccepted {
            admin: config.admin
        });
        Ok(())
    }

    /// Admin withdraws a pending proposal.
    pub fn cancel_admin_proposal(ctx: Context<AdminOnly>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        let admin = config.pending_admin;
        config.pending_admin = Pubkey::default();
        emit!(AdminProposalCancelled { admin });
        Ok(())
    }

    /// Blocks new jobs and offers. Never blocks payouts or refunds.
    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        ctx.accounts.config.paused = paused;
        Ok(())
    }

    pub fn register_introer(
        ctx: Context<RegisterIntroer>,
        badge_id: [u8; 8],
        name: [u8; TEXT_LEN],
    ) -> Result<()> {
        check_text(&name)?;
        let wallet = ctx.accounts.wallet.key();
        let introer = &mut ctx.accounts.introer;
        introer.set_inner(Introer {
            wallet,
            badge_id,
            name,
            jobs_done: 0,
            earned: 0,
            created_at: Clock::get()?.unix_timestamp,
            bump: ctx.bumps.introer,
        });
        emit!(IntroerRegistered {
            introer: introer.key(),
            wallet,
            badge_id,
        });
        Ok(())
    }

    pub fn update_introer(
        ctx: Context<UpdateIntroer>,
        badge_id: [u8; 8],
        name: [u8; TEXT_LEN],
    ) -> Result<()> {
        check_text(&name)?;
        let introer = &mut ctx.accounts.introer;
        introer.badge_id = badge_id;
        introer.name = name;
        Ok(())
    }

    /// Posts a job with `bid` lamports held in the job account, and lists
    /// it on the board.
    pub fn post_job(
        ctx: Context<PostJob>,
        nonce: u64,
        who: [u8; TEXT_LEN],
        company: [u8; TEXT_LEN],
        telegram: [u8; TEXT_LEN],
        bid: u64,
    ) -> Result<()> {
        let a = ctx.accounts;
        require!(!a.config.paused, EscrowError::Paused);
        check_text(&who)?;
        check_text(&company)?;
        check_text(&telegram)?;
        require!(bid >= MIN_BID, EscrowError::BidTooLow);
        require!(bid <= MAX_BID, EscrowError::BidTooHigh);

        system_program::transfer(
            CpiContext::new(
                a.system_program.key(),
                system_program::Transfer {
                    from: a.requester.to_account_info(),
                    to: a.job.to_account_info(),
                },
            ),
            bid,
        )?;

        let job_key = a.job.key();
        let serial = a.board.load_mut()?.add(job_key)?;
        a.job.set_inner(Job {
            requester: a.requester.key(),
            nonce,
            serial,
            bid,
            status: STATUS_OPEN,
            created_at: Clock::get()?.unix_timestamp,
            approved_at: 0,
            made_at: 0,
            approved: Pubkey::default(),
            offer_count: 0,
            offers: [Pubkey::default(); OFFER_RING],
            offers_head: 0,
            who,
            company,
            telegram,
            bump: ctx.bumps.job,
        });
        emit!(JobPosted {
            job: job_key,
            requester: a.requester.key(),
            bid,
        });
        Ok(())
    }

    /// Requester takes back an open job: bid and rent come back.
    pub fn cancel_job(ctx: Context<CancelJob>) -> Result<()> {
        let job = &ctx.accounts.job;
        require!(job.status == STATUS_OPEN, EscrowError::BadStatus);
        emit!(JobCancelled { job: job.key() });
        emit!(Refunded {
            job: job.key(),
            reason: REFUND_CANCELLED,
        });
        Ok(())
    }

    /// A registered introer offers to make the intro.
    pub fn offer(ctx: Context<MakeOffer>) -> Result<()> {
        let a = ctx.accounts;
        require!(!a.config.paused, EscrowError::Paused);
        require!(a.job.status == STATUS_OPEN, EscrowError::BadStatus);
        let wallet = a.wallet.key();
        require_keys_neq!(wallet, a.job.requester, EscrowError::SelfOffer);
        a.offer.set_inner(Offer {
            job: a.job.key(),
            introer: wallet,
            job_serial: a.job.serial,
            created_at: Clock::get()?.unix_timestamp,
            bump: ctx.bumps.offer,
        });
        a.job.add_offer(wallet);
        emit!(Offered {
            job: a.job.key(),
            introer: wallet,
        });
        Ok(())
    }

    /// Introer takes back their offer and its rent. Refused for the
    /// approved offer while its job is live.
    pub fn withdraw_offer(ctx: Context<WithdrawOffer>) -> Result<()> {
        let offer = &ctx.accounts.offer;
        if let Some(job) = live_job(&ctx.accounts.job, offer)? {
            require!(
                job.status == STATUS_OPEN || job.approved != offer.introer,
                EscrowError::OfferInUse
            );
        }
        emit!(OfferWithdrawn {
            job: offer.job,
            introer: offer.introer,
        });
        Ok(())
    }

    /// Anyone: closes an offer whose job is gone, rent to the introer.
    pub fn close_offer(ctx: Context<CloseOffer>) -> Result<()> {
        let offer = &ctx.accounts.offer;
        require!(
            live_job(&ctx.accounts.job, offer)?.is_none(),
            EscrowError::JobLive
        );
        emit!(OfferWithdrawn {
            job: offer.job,
            introer: offer.introer,
        });
        Ok(())
    }

    /// Requester picks one offer.
    pub fn approve(ctx: Context<Approve>, introer_wallet: Pubkey) -> Result<()> {
        let a = ctx.accounts;
        require!(a.job.status == STATUS_OPEN, EscrowError::BadStatus);
        require!(a.offer.job_serial == a.job.serial, EscrowError::StaleOffer);
        a.job.status = STATUS_APPROVED;
        a.job.approved = introer_wallet;
        a.job.approved_at = Clock::get()?.unix_timestamp;
        emit!(Approved {
            job: a.job.key(),
            introer: introer_wallet,
        });
        Ok(())
    }

    /// The approved introer marks the intro made, within `WORK_WINDOW`.
    pub fn mark_made(ctx: Context<MarkMade>) -> Result<()> {
        let job = &mut ctx.accounts.job;
        require!(job.status == STATUS_APPROVED, EscrowError::BadStatus);
        require_keys_eq!(
            job.approved,
            ctx.accounts.wallet.key(),
            EscrowError::Unauthorized
        );
        let now = Clock::get()?.unix_timestamp;
        require!(
            now <= after(job.approved_at, WORK_WINDOW)?,
            EscrowError::WorkExpired
        );
        job.status = STATUS_MADE;
        job.made_at = now;
        emit!(Made {
            job: job.key(),
            made_at: now,
        });
        Ok(())
    }

    /// Requester confirms; the approved introer is paid. The receipt.
    pub fn confirm(ctx: Context<Confirm>) -> Result<()> {
        let a = ctx.accounts;
        require!(
            a.job.status == STATUS_APPROVED || a.job.status == STATUS_MADE,
            EscrowError::BadStatus
        );
        let bid = a.job.bid;
        a.job.sub_lamports(bid)?;
        a.wallet.add_lamports(bid)?;
        let introer = &mut a.introer;
        introer.jobs_done = introer
            .jobs_done
            .checked_add(1)
            .ok_or(EscrowError::Overflow)?;
        introer.earned = introer
            .earned
            .checked_add(bid)
            .ok_or(EscrowError::Overflow)?;
        emit!(Receipt {
            job: a.job.key(),
            introer: introer.wallet,
            requester: a.requester.key(),
            bid,
            jobs_done: introer.jobs_done,
            earned: introer.earned,
        });
        Ok(())
    }

    /// Refunds an approved job never marked made: the requester after
    /// `WORK_WINDOW`, anyone else `CONFIRM_WINDOW` later.
    pub fn refund_expired(ctx: Context<Refund>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.job.status == STATUS_APPROVED, EscrowError::BadStatus);
        let since = a.job.approved_at;
        refund_after(a, since, WORK_WINDOW, REFUND_EXPIRED)
    }

    /// Refunds a made job never confirmed: the requester after
    /// `CONFIRM_WINDOW`, anyone else `CONFIRM_WINDOW` later.
    pub fn refund_unconfirmed(ctx: Context<Refund>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.job.status == STATUS_MADE, EscrowError::BadStatus);
        let since = a.job.made_at;
        refund_after(a, since, CONFIRM_WINDOW, REFUND_UNCONFIRMED)
    }
}

fn after(at: i64, wait: i64) -> Result<i64> {
    Ok(at.checked_add(wait).ok_or(EscrowError::Overflow)?)
}

/// Checks the refund wait (longer for anyone but the requester); the
/// `close` constraint returns bid and rent to the requester.
fn refund_after(a: &Refund, since: i64, wait: i64, reason: u8) -> Result<()> {
    let wait = if a.caller.key() == a.job.requester {
        wait
    } else {
        after(wait, CONFIRM_WINDOW)?
    };
    require!(
        Clock::get()?.unix_timestamp > after(since, wait)?,
        EscrowError::NotExpired
    );
    emit!(Refunded {
        job: a.job.key(),
        reason,
    });
    Ok(())
}

/// The job an offer was made on, if it still exists. A job re-posted at the
/// same address (same requester and nonce) has a new serial and doesn't
/// count.
fn live_job(info: &UncheckedAccount, offer: &Offer) -> Result<Option<Job>> {
    if info.owner != &crate::ID || info.data_is_empty() {
        return Ok(None);
    }
    let data = info.try_borrow_data()?;
    let job = Job::try_deserialize(&mut &data[..])?;
    Ok((job.serial == offer.job_serial).then_some(job))
}

/// Text is UTF-8, non-empty and zero-padded: nothing but zeros after the
/// first zero.
fn check_text(text: &[u8]) -> Result<()> {
    let len = text.iter().position(|b| *b == 0).unwrap_or(text.len());
    let (body, pad) = text.split_at(len);
    require!(len > 0, EscrowError::BadText);
    require!(pad.iter().all(|b| *b == 0), EscrowError::BadText);
    require!(core::str::from_utf8(body).is_ok(), EscrowError::BadText);
    Ok(())
}

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    /// Proposed next admin until it accepts; default when none.
    pub pending_admin: Pubkey,
    /// Blocks `post_job` and `offer` only.
    pub paused: bool,
    pub bump: u8,
}

/// Ring of the newest job addresses, for clients that can't list program
/// accounts. Old entries may point at closed jobs. Zero-copy: too big to
/// deserialize on the stack.
#[account(zero_copy)]
pub struct Board {
    /// Next slot to write.
    pub head: u8,
    pub bump: u8,
    pub padding: [u8; 6],
    /// Jobs ever posted; the next job's serial.
    pub posted: u64,
    pub jobs: [Pubkey; BOARD_LEN],
}

impl Board {
    /// Lists `job` at `head`, advances it, and returns the job's serial.
    fn add(&mut self, job: Pubkey) -> Result<u64> {
        let slot = usize::from(self.head) % BOARD_LEN;
        if let Some(entry) = self.jobs.get_mut(slot) {
            *entry = job;
        }
        self.head = ((slot + 1) % BOARD_LEN) as u8;
        let serial = self.posted;
        self.posted = serial.checked_add(1).ok_or(EscrowError::Overflow)?;
        Ok(serial)
    }
}

#[account]
#[derive(InitSpace)]
pub struct Introer {
    pub wallet: Pubkey,
    pub badge_id: [u8; 8],
    /// UTF-8, zero-padded.
    pub name: [u8; TEXT_LEN],
    pub jobs_done: u32,
    pub earned: u64,
    pub created_at: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Job {
    pub requester: Pubkey,
    pub nonce: u64,
    /// Unique per post (from `Board.posted`); ties offers to this post even
    /// if the same address is reused later.
    pub serial: u64,
    pub bid: u64,
    pub status: u8,
    pub created_at: i64,
    pub approved_at: i64,
    pub made_at: i64,
    /// Approved introer wallet; default until approved.
    pub approved: Pubkey,
    /// Offers ever made (saturates).
    pub offer_count: u16,
    /// Newest offering introer wallets, a ring.
    pub offers: [Pubkey; OFFER_RING],
    /// Next ring slot to write.
    pub offers_head: u8,
    /// UTF-8, zero-padded.
    pub who: [u8; TEXT_LEN],
    pub company: [u8; TEXT_LEN],
    pub telegram: [u8; TEXT_LEN],
    pub bump: u8,
}

impl Job {
    fn add_offer(&mut self, wallet: Pubkey) {
        let slot = usize::from(self.offers_head) % OFFER_RING;
        if let Some(entry) = self.offers.get_mut(slot) {
            *entry = wallet;
        }
        self.offers_head = ((slot + 1) % OFFER_RING) as u8;
        self.offer_count = self.offer_count.saturating_add(1);
    }
}

#[account]
#[derive(InitSpace)]
pub struct Offer {
    pub job: Pubkey,
    /// Introer wallet.
    pub introer: Pubkey,
    /// `Job.serial` of the post this offer was made on.
    pub job_serial: u64,
    pub created_at: i64,
    pub bump: u8,
}

// Account orders are part of the client contract (docs/spec-v2.md): signer first.

#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [b"config"], bump)]
    pub config: Account<'info, Config>,
    #[account(init, payer = authority, space = 8 + core::mem::size_of::<Board>(), seeds = [b"board"], bump)]
    pub board: AccountLoader<'info, Board>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ EscrowError::NotUpgradeAuthority)]
    pub program: Program<'info, program::IntroEscrow>,
    #[account(constraint = program_data.upgrade_authority_address == Some(authority.key()) @ EscrowError::NotUpgradeAuthority)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = admin @ EscrowError::Unauthorized)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    pub pending_admin: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = pending_admin @ EscrowError::Unauthorized)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct RegisterIntroer<'info> {
    #[account(mut)]
    pub wallet: Signer<'info>,
    #[account(init, payer = wallet, space = 8 + Introer::INIT_SPACE, seeds = [b"introer", wallet.key().as_ref()], bump)]
    pub introer: Account<'info, Introer>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateIntroer<'info> {
    pub wallet: Signer<'info>,
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
}

#[derive(Accounts)]
#[instruction(nonce: u64)]
pub struct PostJob<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"board"], bump)]
    pub board: AccountLoader<'info, Board>,
    #[account(
        init,
        payer = requester,
        space = 8 + Job::INIT_SPACE,
        seeds = [b"job", requester.key().as_ref(), &nonce.to_le_bytes()],
        bump
    )]
    pub job: Box<Account<'info, Job>>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CancelJob<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(
        mut,
        close = requester,
        seeds = [b"job", requester.key().as_ref(), &job.nonce.to_le_bytes()],
        bump = job.bump,
        has_one = requester @ EscrowError::Unauthorized
    )]
    pub job: Box<Account<'info, Job>>,
}

#[derive(Accounts)]
pub struct MakeOffer<'info> {
    #[account(mut)]
    pub wallet: Signer<'info>,
    #[account(seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    /// Proves the wallet is a registered introer.
    #[account(seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(mut, seeds = [b"job", job.requester.as_ref(), &job.nonce.to_le_bytes()], bump = job.bump)]
    pub job: Box<Account<'info, Job>>,
    #[account(
        init,
        payer = wallet,
        space = 8 + Offer::INIT_SPACE,
        seeds = [b"offer", job.key().as_ref(), wallet.key().as_ref()],
        bump
    )]
    pub offer: Account<'info, Offer>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct WithdrawOffer<'info> {
    #[account(mut)]
    pub wallet: Signer<'info>,
    #[account(
        mut,
        close = wallet,
        seeds = [b"offer", offer.job.as_ref(), wallet.key().as_ref()],
        bump = offer.bump
    )]
    pub offer: Account<'info, Offer>,
    /// CHECK: must be `offer.job`; read only to see if it is still live.
    #[account(address = offer.job @ EscrowError::WrongJob)]
    pub job: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct CloseOffer<'info> {
    pub caller: Signer<'info>,
    #[account(
        mut,
        close = wallet,
        seeds = [b"offer", offer.job.as_ref(), offer.introer.as_ref()],
        bump = offer.bump
    )]
    pub offer: Account<'info, Offer>,
    /// CHECK: must be `offer.introer`; receives the rent.
    #[account(mut, address = offer.introer @ EscrowError::WrongWallet)]
    pub wallet: UncheckedAccount<'info>,
    /// CHECK: must be `offer.job`; read only to see if it is still live.
    #[account(address = offer.job @ EscrowError::WrongJob)]
    pub job: UncheckedAccount<'info>,
}

#[derive(Accounts)]
#[instruction(introer_wallet: Pubkey)]
pub struct Approve<'info> {
    pub requester: Signer<'info>,
    #[account(
        mut,
        seeds = [b"job", requester.key().as_ref(), &job.nonce.to_le_bytes()],
        bump = job.bump,
        has_one = requester @ EscrowError::Unauthorized
    )]
    pub job: Box<Account<'info, Job>>,
    #[account(seeds = [b"offer", job.key().as_ref(), introer_wallet.as_ref()], bump = offer.bump)]
    pub offer: Account<'info, Offer>,
}

#[derive(Accounts)]
pub struct MarkMade<'info> {
    pub wallet: Signer<'info>,
    #[account(mut, seeds = [b"job", job.requester.as_ref(), &job.nonce.to_le_bytes()], bump = job.bump)]
    pub job: Box<Account<'info, Job>>,
}

#[derive(Accounts)]
pub struct Confirm<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(
        mut,
        close = requester,
        seeds = [b"job", requester.key().as_ref(), &job.nonce.to_le_bytes()],
        bump = job.bump,
        has_one = requester @ EscrowError::Unauthorized
    )]
    pub job: Box<Account<'info, Job>>,
    #[account(mut, seeds = [b"introer", job.approved.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    /// CHECK: must be `job.approved`; receives the bid.
    #[account(mut, address = job.approved @ EscrowError::WrongWallet)]
    pub wallet: UncheckedAccount<'info>,
}

/// `refund_expired` and `refund_unconfirmed`.
#[derive(Accounts)]
pub struct Refund<'info> {
    pub caller: Signer<'info>,
    #[account(
        mut,
        close = requester,
        seeds = [b"job", requester.key().as_ref(), &job.nonce.to_le_bytes()],
        bump = job.bump,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub job: Box<Account<'info, Job>>,
    /// CHECK: must be `job.requester` (has_one); receives bid and rent.
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[event]
pub struct AdminProposed {
    pub admin: Pubkey,
}

#[event]
pub struct AdminAccepted {
    pub admin: Pubkey,
}

#[event]
pub struct AdminProposalCancelled {
    /// The proposal that was cleared (default if none).
    pub admin: Pubkey,
}

#[event]
pub struct IntroerRegistered {
    pub introer: Pubkey,
    pub wallet: Pubkey,
    pub badge_id: [u8; 8],
}

#[event]
pub struct JobPosted {
    pub job: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
}

#[event]
pub struct JobCancelled {
    pub job: Pubkey,
}

#[event]
pub struct Offered {
    pub job: Pubkey,
    /// Introer wallet.
    pub introer: Pubkey,
}

#[event]
pub struct OfferWithdrawn {
    pub job: Pubkey,
    pub introer: Pubkey,
}

#[event]
pub struct Approved {
    pub job: Pubkey,
    pub introer: Pubkey,
}

#[event]
pub struct Made {
    pub job: Pubkey,
    pub made_at: i64,
}

#[event]
pub struct Receipt {
    pub job: Pubkey,
    /// Introer wallet.
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
    pub jobs_done: u32,
    pub earned: u64,
}

#[event]
pub struct Refunded {
    pub job: Pubkey,
    /// One of the `REFUND_*` constants.
    pub reason: u8,
}

#[error_code]
pub enum EscrowError {
    #[msg("Signer is not the program upgrade authority")]
    NotUpgradeAuthority,
    #[msg("Signer is not allowed")]
    Unauthorized,
    #[msg("Admin can't be the default key")]
    NoAdmin,
    #[msg("New jobs and offers are paused")]
    Paused,
    #[msg("Text is empty, not UTF-8 or not zero-padded")]
    BadText,
    #[msg("Bid is above the max")]
    BidTooHigh,
    #[msg("Bid is below the min")]
    BidTooLow,
    #[msg("Requesters can't offer on their own job")]
    SelfOffer,
    #[msg("Job is in the wrong state")]
    BadStatus,
    #[msg("Offer was made on an earlier post at this address")]
    StaleOffer,
    #[msg("The approved offer can't be withdrawn while its job is live")]
    OfferInUse,
    #[msg("The job is still live")]
    JobLive,
    #[msg("Job does not match")]
    WrongJob,
    #[msg("Wallet does not match")]
    WrongWallet,
    #[msg("Requester does not match")]
    WrongRequester,
    #[msg("Work window has passed")]
    WorkExpired,
    #[msg("Not expired yet")]
    NotExpired,
    #[msg("Math overflow")]
    Overflow,
}
