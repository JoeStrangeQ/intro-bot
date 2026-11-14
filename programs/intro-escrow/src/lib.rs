//! Intro Bot escrow: public intro requests with SOL bids held until the intro
//! is confirmed. See `docs/spec.md` ("Program: intro_escrow").
#![allow(unexpected_cfgs, reason = "anchor macros emit cfgs")]
#![allow(clippy::needless_lifetimes, reason = "anchor accounts structs")]

use anchor_lang::prelude::*;
use anchor_lang::system_program;

declare_id!("GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC");

pub const LAMPORTS_PER_SOL: u64 = 1_000_000_000;
pub const MAX_BID: u64 = 100 * LAMPORTS_PER_SOL;
pub const MIN_BID_FLOOR: u64 = LAMPORTS_PER_SOL / 100;
pub const MAX_OPEN: u8 = 5;
pub const CONFIRM_WINDOW: i64 = 72 * 60 * 60;
pub const WORK_WINDOW: i64 = 7 * 24 * 60 * 60;
pub const MAX_TARGET: usize = 64;
pub const MAX_TELEGRAM: usize = 32;
pub const MAX_OFFER: usize = 64;

pub const STATUS_OPEN: u8 = 0;
pub const STATUS_ACCEPTED: u8 = 1;
pub const STATUS_MADE: u8 = 2;
pub const STATUS_DISPUTED: u8 = 3;

/// `Refunded.reason` values.
pub const REFUND_WITHDRAWN: u8 = 0;
pub const REFUND_DECLINED: u8 = 1;
pub const REFUND_OUTBID: u8 = 2;
pub const REFUND_EXPIRED: u8 = 3;
pub const REFUND_ARBITER: u8 = 4;

#[program]
pub mod intro_escrow {
    use super::*;

    /// Creates the config. Only the program's upgrade authority can call it;
    /// the signer becomes the admin.
    pub fn init_config(ctx: Context<InitConfig>, arbiter: Pubkey, cap_total: u64) -> Result<()> {
        ctx.accounts.config.set_inner(Config {
            admin: ctx.accounts.authority.key(),
            arbiter,
            paused: false,
            cap_total,
            total_held: 0,
            bump: ctx.bumps.config,
        });
        Ok(())
    }

    pub fn set_admin(ctx: Context<AdminOnly>, admin: Pubkey) -> Result<()> {
        ctx.accounts.config.admin = admin;
        Ok(())
    }

    pub fn set_arbiter(ctx: Context<AdminOnly>, arbiter: Pubkey) -> Result<()> {
        ctx.accounts.config.arbiter = arbiter;
        Ok(())
    }

    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        ctx.accounts.config.paused = paused;
        Ok(())
    }

    pub fn set_cap(ctx: Context<AdminOnly>, cap_total: u64) -> Result<()> {
        ctx.accounts.config.cap_total = cap_total;
        Ok(())
    }

    pub fn register_introer(
        ctx: Context<RegisterIntroer>,
        badge_id: [u8; 8],
        offer: String,
        min_bid: u64,
    ) -> Result<()> {
        check_terms(&offer, min_bid)?;
        let introer = &mut ctx.accounts.introer;
        introer.set_inner(Introer {
            wallet: ctx.accounts.wallet.key(),
            badge_id,
            offer,
            min_bid,
            next_id: 0,
            open_count: 0,
            jobs_done: 0,
            earned: 0,
            created_at: Clock::get()?.unix_timestamp,
            bump: ctx.bumps.introer,
        });
        emit!(IntroerRegistered {
            introer: introer.key(),
            wallet: introer.wallet,
            badge_id,
            min_bid,
        });
        Ok(())
    }

    pub fn update_introer(ctx: Context<UpdateIntroer>, offer: String, min_bid: u64) -> Result<()> {
        check_terms(&offer, min_bid)?;
        let introer = &mut ctx.accounts.introer;
        introer.offer = offer;
        introer.min_bid = min_bid;
        Ok(())
    }

    /// Posts a request with `amount` lamports held in the request account.
    /// With `MAX_OPEN` open requests, `lowest` must be the lowest of them
    /// (the other open ones go in remaining accounts); it is refunded.
    pub fn bid<'info>(
        ctx: Context<'info, Bid<'info>>,
        target: String,
        telegram: String,
        amount: u64,
    ) -> Result<()> {
        let accounts = ctx.accounts;
        require!(!accounts.config.paused, EscrowError::Paused);
        require!(
            !target.is_empty() && target.len() <= MAX_TARGET,
            EscrowError::TextTooLong
        );
        require!(telegram.len() <= MAX_TELEGRAM, EscrowError::TextTooLong);
        require!(amount <= MAX_BID, EscrowError::BidTooHigh);
        require!(
            amount >= accounts.introer.min_bid && amount >= MIN_BID_FLOOR,
            EscrowError::BidTooLow
        );

        if accounts.introer.open_count >= MAX_OPEN {
            evict_lowest(
                &mut accounts.config,
                &mut accounts.introer,
                accounts.lowest.as_ref(),
                accounts.lowest_requester.as_ref(),
                ctx.remaining_accounts,
                amount,
            )?;
        }

        let held = accounts
            .config
            .total_held
            .checked_add(amount)
            .ok_or(EscrowError::Overflow)?;
        require!(held <= accounts.config.cap_total, EscrowError::OverCap);
        accounts.config.total_held = held;

        system_program::transfer(
            CpiContext::new(
                accounts.system_program.key(),
                system_program::Transfer {
                    from: accounts.requester.to_account_info(),
                    to: accounts.request.to_account_info(),
                },
            ),
            amount,
        )?;

        let introer = &mut accounts.introer;
        let id = introer.next_id;
        introer.next_id = id.checked_add(1).ok_or(EscrowError::Overflow)?;
        introer.open_count = introer
            .open_count
            .checked_add(1)
            .ok_or(EscrowError::Overflow)?;
        accounts.request.set_inner(Request {
            introer: introer.key(),
            requester: accounts.requester.key(),
            id,
            target,
            telegram,
            bid: amount,
            status: STATUS_OPEN,
            created_at: Clock::get()?.unix_timestamp,
            accepted_at: 0,
            made_at: 0,
            bump: ctx.bumps.request,
        });
        emit!(BidPlaced {
            request: accounts.request.key(),
            introer: introer.key(),
            requester: accounts.requester.key(),
            bid: amount,
        });
        Ok(())
    }

    /// Requester takes back an open request.
    pub fn withdraw(ctx: Context<Withdraw>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_OPEN, EscrowError::BadStatus);
        close_open(&mut a.config, &mut a.introer, &a.request)?;
        emit!(Withdrawn {
            request: a.request.key()
        });
        emit_refund(&a.request, REFUND_WITHDRAWN);
        Ok(())
    }

    pub fn accept(ctx: Context<IntroerStep>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_OPEN, EscrowError::BadStatus);
        a.introer.open_count = a
            .introer
            .open_count
            .checked_sub(1)
            .ok_or(EscrowError::Overflow)?;
        a.request.status = STATUS_ACCEPTED;
        a.request.accepted_at = Clock::get()?.unix_timestamp;
        emit!(Accepted {
            request: a.request.key()
        });
        Ok(())
    }

    /// Introer turns down an open request; it is refunded.
    pub fn decline(ctx: Context<Decline>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_OPEN, EscrowError::BadStatus);
        close_open(&mut a.config, &mut a.introer, &a.request)?;
        emit!(Declined {
            request: a.request.key()
        });
        emit_refund(&a.request, REFUND_DECLINED);
        Ok(())
    }

    pub fn mark_made(ctx: Context<IntroerStep>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_ACCEPTED, EscrowError::BadStatus);
        let now = Clock::get()?.unix_timestamp;
        a.request.status = STATUS_MADE;
        a.request.made_at = now;
        emit!(Made {
            request: a.request.key(),
            made_at: now,
        });
        Ok(())
    }

    /// Requester confirms the intro; the introer is paid.
    pub fn confirm(ctx: Context<Confirm>) -> Result<()> {
        let a = ctx.accounts;
        require!(
            a.request.status == STATUS_MADE || a.request.status == STATUS_ACCEPTED,
            EscrowError::BadStatus
        );
        pay_out(
            &mut a.config,
            &mut a.introer,
            &a.request,
            &a.wallet.to_account_info(),
            a.requester.key(),
        )
    }

    pub fn dispute(ctx: Context<Dispute>) -> Result<()> {
        let request = &mut ctx.accounts.request;
        require!(request.status == STATUS_MADE, EscrowError::BadStatus);
        let deadline = request
            .made_at
            .checked_add(CONFIRM_WINDOW)
            .ok_or(EscrowError::Overflow)?;
        require!(
            Clock::get()?.unix_timestamp <= deadline,
            EscrowError::WindowClosed
        );
        request.status = STATUS_DISPUTED;
        emit!(Disputed {
            request: request.key()
        });
        Ok(())
    }

    /// Anyone: pays the introer once the confirm window has passed.
    pub fn release_expired(ctx: Context<Release>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_MADE, EscrowError::BadStatus);
        let deadline = a
            .request
            .made_at
            .checked_add(CONFIRM_WINDOW)
            .ok_or(EscrowError::Overflow)?;
        require!(
            Clock::get()?.unix_timestamp > deadline,
            EscrowError::NotExpired
        );
        pay_out(
            &mut a.config,
            &mut a.introer,
            &a.request,
            &a.wallet.to_account_info(),
            a.requester.key(),
        )
    }

    /// Anyone: refunds an accepted request the introer never marked made.
    pub fn refund_expired(ctx: Context<RefundExpired>) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_ACCEPTED, EscrowError::BadStatus);
        let deadline = a
            .request
            .accepted_at
            .checked_add(WORK_WINDOW)
            .ok_or(EscrowError::Overflow)?;
        require!(
            Clock::get()?.unix_timestamp > deadline,
            EscrowError::NotExpired
        );
        release_held(&mut a.config, a.request.bid)?;
        emit_refund(&a.request, REFUND_EXPIRED);
        Ok(())
    }

    /// Arbiter settles a dispute either way.
    pub fn resolve(ctx: Context<Resolve>, to_introer: bool) -> Result<()> {
        let a = ctx.accounts;
        require!(a.request.status == STATUS_DISPUTED, EscrowError::BadStatus);
        if to_introer {
            pay_out(
                &mut a.config,
                &mut a.introer,
                &a.request,
                &a.wallet.to_account_info(),
                a.requester.key(),
            )
        } else {
            release_held(&mut a.config, a.request.bid)?;
            emit_refund(&a.request, REFUND_ARBITER);
            Ok(())
        }
    }
}

fn check_terms(offer: &str, min_bid: u64) -> Result<()> {
    require!(offer.len() <= MAX_OFFER, EscrowError::TextTooLong);
    require!(min_bid >= MIN_BID_FLOOR, EscrowError::BidTooLow);
    require!(min_bid <= MAX_BID, EscrowError::BidTooHigh);
    Ok(())
}

fn release_held(config: &mut Config, bid: u64) -> Result<()> {
    config.total_held = config
        .total_held
        .checked_sub(bid)
        .ok_or(EscrowError::Overflow)?;
    Ok(())
}

/// Book-keeping for closing an open request (the account itself is closed
/// by the `close` constraint, returning bid and rent to the requester).
fn close_open(config: &mut Config, introer: &mut Introer, request: &Request) -> Result<()> {
    release_held(config, request.bid)?;
    introer.open_count = introer
        .open_count
        .checked_sub(1)
        .ok_or(EscrowError::Overflow)?;
    Ok(())
}

/// Moves the bid to the introer wallet and records the receipt. The `close`
/// constraint then returns the rent to the requester.
fn pay_out<'info>(
    config: &mut Config,
    introer: &mut Account<'info, Introer>,
    request: &Account<'info, Request>,
    wallet: &AccountInfo<'info>,
    requester: Pubkey,
) -> Result<()> {
    let bid = request.bid;
    release_held(config, bid)?;
    move_lamports(&request.to_account_info(), wallet, bid)?;
    introer.jobs_done = introer
        .jobs_done
        .checked_add(1)
        .ok_or(EscrowError::Overflow)?;
    introer.earned = introer
        .earned
        .checked_add(bid)
        .ok_or(EscrowError::Overflow)?;
    emit!(Receipt {
        request: request.key(),
        introer: introer.key(),
        requester,
        bid,
        jobs_done: introer.jobs_done,
        earned: introer.earned,
    });
    Ok(())
}

fn move_lamports(from: &AccountInfo, to: &AccountInfo, amount: u64) -> Result<()> {
    let from_left = from
        .lamports()
        .checked_sub(amount)
        .ok_or(EscrowError::Overflow)?;
    let to_total = to
        .lamports()
        .checked_add(amount)
        .ok_or(EscrowError::Overflow)?;
    **from.try_borrow_mut_lamports()? = from_left;
    **to.try_borrow_mut_lamports()? = to_total;
    Ok(())
}

fn emit_refund(request: &Account<Request>, reason: u8) {
    emit!(Refunded {
        request: request.key(),
        reason,
    });
}

/// Refunds and closes the lowest open request so a higher bid can take its
/// slot. `others` must be every other open request of this introer, which
/// proves `lowest` really is the lowest.
fn evict_lowest<'info>(
    config: &mut Config,
    introer: &mut Account<'info, Introer>,
    lowest: Option<&Account<'info, Request>>,
    lowest_requester: Option<&UncheckedAccount<'info>>,
    others: &'info [AccountInfo<'info>],
    amount: u64,
) -> Result<()> {
    let (Some(lowest), Some(lowest_requester)) = (lowest, lowest_requester) else {
        return err!(EscrowError::QueueFull);
    };
    require_keys_eq!(lowest.introer, introer.key(), EscrowError::WrongRequest);
    require!(lowest.status == STATUS_OPEN, EscrowError::BadStatus);
    require_keys_eq!(
        lowest_requester.key(),
        lowest.requester,
        EscrowError::WrongRequester
    );
    require!(amount > lowest.bid, EscrowError::BidTooLow);

    let needed = usize::from(introer.open_count.saturating_sub(1));
    require!(others.len() == needed, EscrowError::WrongRequest);
    let mut seen: Vec<Pubkey> = Vec::with_capacity(needed.saturating_add(1));
    seen.push(lowest.key());
    for info in others {
        require!(!seen.contains(info.key), EscrowError::WrongRequest);
        seen.push(info.key());
        let other: Account<Request> = Account::try_from(info)?;
        require_keys_eq!(other.introer, introer.key(), EscrowError::WrongRequest);
        require!(other.status == STATUS_OPEN, EscrowError::WrongRequest);
        require!(lowest.bid <= other.bid, EscrowError::NotLowest);
    }

    close_open(config, introer, lowest)?;
    lowest.close(lowest_requester.to_account_info())?;
    emit!(Outbid {
        request: lowest.key(),
        requester: lowest.requester,
        bid: lowest.bid,
        new_bid: amount,
    });
    emit_refund(lowest, REFUND_OUTBID);
    Ok(())
}

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    pub arbiter: Pubkey,
    pub paused: bool,
    /// Max lamports held across all requests.
    pub cap_total: u64,
    /// Sum of the bids of all live requests.
    pub total_held: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Introer {
    pub wallet: Pubkey,
    pub badge_id: [u8; 8],
    #[max_len(MAX_OFFER)]
    pub offer: String,
    pub min_bid: u64,
    pub next_id: u64,
    pub open_count: u8,
    pub jobs_done: u32,
    pub earned: u64,
    pub created_at: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Request {
    /// Introer PDA.
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub id: u64,
    #[max_len(MAX_TARGET)]
    pub target: String,
    #[max_len(MAX_TELEGRAM)]
    pub telegram: String,
    pub bid: u64,
    pub status: u8,
    pub created_at: i64,
    pub accepted_at: i64,
    pub made_at: i64,
    pub bump: u8,
}

#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [b"config"], bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ EscrowError::NotUpgradeAuthority)]
    pub program: Program<'info, program::IntroEscrow>,
    #[account(constraint = program_data.upgrade_authority_address == Some(authority.key()) @ EscrowError::NotUpgradeAuthority)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = admin @ EscrowError::Unauthorized)]
    pub config: Account<'info, Config>,
    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct RegisterIntroer<'info> {
    #[account(init, payer = wallet, space = 8 + Introer::INIT_SPACE, seeds = [b"introer", wallet.key().as_ref()], bump)]
    pub introer: Account<'info, Introer>,
    #[account(mut)]
    pub wallet: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateIntroer<'info> {
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
    pub wallet: Signer<'info>,
}

#[derive(Accounts)]
pub struct Bid<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        init,
        payer = requester,
        space = 8 + Request::INIT_SPACE,
        seeds = [b"request", introer.key().as_ref(), &introer.next_id.to_le_bytes()],
        bump
    )]
    pub request: Account<'info, Request>,
    #[account(mut)]
    pub requester: Signer<'info>,
    /// Lowest open request, only needed when the queue is full.
    #[account(mut)]
    pub lowest: Option<Account<'info, Request>>,
    /// CHECK: checked against `lowest.requester` before any refund.
    #[account(mut)]
    pub lowest_requester: Option<UncheckedAccount<'info>>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    #[account(mut)]
    pub requester: Signer<'info>,
}

#[derive(Accounts)]
pub struct IntroerStep<'info> {
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest
    )]
    pub request: Account<'info, Request>,
    pub wallet: Signer<'info>,
}

#[derive(Accounts)]
pub struct Decline<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"introer", wallet.key().as_ref()], bump = introer.bump, has_one = wallet @ EscrowError::Unauthorized)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    pub wallet: Signer<'info>,
    /// CHECK: must equal `request.requester` (has_one).
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct Confirm<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `introer.wallet`; receives the bid.
    #[account(mut, address = introer.wallet @ EscrowError::WrongWallet)]
    pub wallet: UncheckedAccount<'info>,
    #[account(mut)]
    pub requester: Signer<'info>,
}

#[derive(Accounts)]
pub struct Dispute<'info> {
    #[account(
        mut,
        seeds = [b"request", request.introer.as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    pub requester: Signer<'info>,
}

#[derive(Accounts)]
pub struct Release<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `introer.wallet`; receives the bid.
    #[account(mut, address = introer.wallet @ EscrowError::WrongWallet)]
    pub wallet: UncheckedAccount<'info>,
    /// CHECK: must equal `request.requester` (has_one); receives the rent.
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct RefundExpired<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `request.requester` (has_one); receives bid and rent.
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct Resolve<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = arbiter @ EscrowError::Unauthorized)]
    pub config: Account<'info, Config>,
    pub arbiter: Signer<'info>,
    #[account(mut, seeds = [b"introer", introer.wallet.as_ref()], bump = introer.bump)]
    pub introer: Account<'info, Introer>,
    #[account(
        mut,
        close = requester,
        seeds = [b"request", introer.key().as_ref(), &request.id.to_le_bytes()],
        bump = request.bump,
        has_one = introer @ EscrowError::WrongRequest,
        has_one = requester @ EscrowError::WrongRequester
    )]
    pub request: Account<'info, Request>,
    /// CHECK: must equal `introer.wallet`; receives the bid.
    #[account(mut, address = introer.wallet @ EscrowError::WrongWallet)]
    pub wallet: UncheckedAccount<'info>,
    /// CHECK: must equal `request.requester` (has_one); receives the rent.
    #[account(mut)]
    pub requester: UncheckedAccount<'info>,
}

#[event]
pub struct IntroerRegistered {
    pub introer: Pubkey,
    pub wallet: Pubkey,
    pub badge_id: [u8; 8],
    pub min_bid: u64,
}

#[event]
pub struct BidPlaced {
    pub request: Pubkey,
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
}

#[event]
pub struct Outbid {
    /// The refunded request.
    pub request: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
    pub new_bid: u64,
}

#[event]
pub struct Withdrawn {
    pub request: Pubkey,
}

#[event]
pub struct Accepted {
    pub request: Pubkey,
}

#[event]
pub struct Declined {
    pub request: Pubkey,
}

#[event]
pub struct Made {
    pub request: Pubkey,
    pub made_at: i64,
}

#[event]
pub struct Disputed {
    pub request: Pubkey,
}

#[event]
pub struct Receipt {
    pub request: Pubkey,
    pub introer: Pubkey,
    pub requester: Pubkey,
    pub bid: u64,
    pub jobs_done: u32,
    pub earned: u64,
}

#[event]
pub struct Refunded {
    pub request: Pubkey,
    /// One of the `REFUND_*` constants.
    pub reason: u8,
}

#[error_code]
pub enum EscrowError {
    #[msg("Signer is not the program upgrade authority")]
    NotUpgradeAuthority,
    #[msg("Signer is not allowed")]
    Unauthorized,
    #[msg("Bids are paused")]
    Paused,
    #[msg("Text is empty or too long")]
    TextTooLong,
    #[msg("Bid is above the max")]
    BidTooHigh,
    #[msg("Bid is below the min")]
    BidTooLow,
    #[msg("Escrow cap reached")]
    OverCap,
    #[msg("Queue is full: pass the lowest open request")]
    QueueFull,
    #[msg("Passed request is not the lowest open one")]
    NotLowest,
    #[msg("Request does not belong to this introer")]
    WrongRequest,
    #[msg("Requester does not match")]
    WrongRequester,
    #[msg("Wallet does not match the introer")]
    WrongWallet,
    #[msg("Request is in the wrong state")]
    BadStatus,
    #[msg("Confirm window has closed")]
    WindowClosed,
    #[msg("Not expired yet")]
    NotExpired,
    #[msg("Math overflow")]
    Overflow,
}
