# GTStar

**Mine GTS. Win SUI.**

GTStar is a fair-launch mining game on [Sui](https://sui.io). Every 60 seconds, players deploy SUI across a 5×5 board. One tile wins. Its miners split the pot, and every SUI deployed in the round mines GTS, win or lose. GTS has no SUI reserve: its price is set by the market.

GTS is built to hold value: a 1,000,000 cap and a 2,000 a day mint limit sealed in immutable contracts, a round that needs 7 SUI to mint 1 GTS (about 0.67 SUI of fees per GTS mined), 3% of every losing pot spent on buying GTS and burning it, and 2% added to liquidity in positions held by the game, which has no function to take them out. None of that sets the price.

- App: https://minegts.fun
- Docs: https://minegts.fun/docs.html (the short version; this README is the full technical reference)
- X: https://x.com/MineGTS1
- Telegram: https://t.me/MineGTS

> **Relaunch, 2026-09-29.** GTStar relaunched with a new GTS token and a new game. The first token and game are archived in [`legacy/`](legacy); their reserve stays immutable, so old GTS (the first token) can still be redeemed there.

## Overview

| | |
|---|---|
| Max supply | 1,000,000 GTS, locked for good: the mint authority is sealed in an immutable contract (`supply_lock`), so no one can raise the cap, the owner included |
| Daily mint limit | At most 2,000 GTS minted per UTC day, sealed in a second immutable contract (`mint_limit`). A full day of 60-second rounds mints at most 1,440 GTS. If the limit is ever reached, a claim still pays its SUI at once; the GTS that did not fit is recorded as owed to the player and minted to their unrefined balance once there is room (after 00:00 UTC), by their next claim or when they call `claim_owed` themselves (only the player can: it moves their withdraw clock) |
| Premine / team / presale | None |
| Emission | 1 GTS per round, shared by SUI deployed, win or lose (full reward from 7 SUI in the round, less for smaller rounds: 1 SUI mines about 0.143 GTS; until 2026-10-01 the full reward needed 1 SUI, so 1 SUI mined 1 GTS. Mining a GTS now costs about 0.67 SUI of fees, more than its market price was that day, and the 3% buyback then burns about as much GTS as rounds mint). Every 15,658 rounds the reward drops 1.425%. The cut follows rounds, not GTS mined, so the 1,000,000 cap is a ceiling: full rounds every time would mint about 1,099,000, and rounds below 7 SUI mint less, so the final supply can end below 1,000,000. Counted by rounds played, not by date. The emission can only go down (a lower reward, a faster cut, shorter steps), never up |
| Losing pot | 90% winners · 3% Wealth Fund · 3% buyback and burn (GTS bought on Cetus and burned for good) · 2% liquidity (half buys GTS, both halves added to the Cetus GTS/SUI pool, in a position held by the game, which has no function to take it out) · 1% stakers (SUI) · 1% creator. Winners split it by their stake on the winning tile and keep all of it, no cut. At most 5 tiles per wallet per round (one miner per wallet per round) |
| Wealth Fund | 3% of every losing pot (less the draw reward), and the whole pot less fees when no one is on the winning tile. Every round has a 1 in 250 chance to pay the whole fund to one ticket holder. Tickets = the fees a player paid on SUI they lost since the last payout (10% of it), so extra wallets give no extra tickets. Six GTStar wallets named in the contract get none (House, Bot 1-3, Matcher, Shield); GTStar's other bots collect tickets like any player |
| Unrefined GTS | Mined GTS waits in your unrefined balance. Withdrawing is free once your 7-day clock has run out; before that the fee falls from 10% to 0: half is burned and half is shared by everyone still holding unrefined GTS (all of it burned if no one else holds). The clock is weighted by amount: GTS mined now starts its own 7 days and the clock moves to the average of the GTS held and the GTS mined, by their amounts (5 GTS with 3 days left plus 1 new GTS: 3 days 16 hours for all 6). GTS held longer than 7 days counts as 7 days, so a small old balance cannot free a large new one. Every wallet pays the same fee, GTStar's bots included |
| Buyback and liquidity | Run by the game itself, inside the draw (`settle_v3`), on the Cetus GTS/SUI pool: no keeper wallet, and no function lets any address take either balance (true of the code running now; while the game is upgradable, new code could change that). From 0.005 SUI saved the draw buys GTS and burns it in the same transaction; from 0.05 SUI saved it buys GTS with 49% and adds the GTS with the matching SUI to a position locked in the game (20 positions, none can be taken out). A draw's buys can lift the pool price at most 2% above a reference price (the price after the previous draw's buys, itself rising at most 2% a draw), so pushing the price up before a draw does not make the game buy higher. Anyone can add to the locked liquidity: `lock_position` gives the game a whole Cetus position of the pool, `give_liquidity` adds GTS and SUI at the pool price to the game's first position (nothing is swapped). `compound_fees`, open to anyone, puts the positions' trading fees back into the pool, only while the pool price is within 2% of that reference price. If the market stops (Cetus paused, or on a version the game is not linked to), nothing depends on the owner: after 6 hours without a usable market the plain draw pays its caller, and after 7 days the SUI saved for the buyback and liquidity, and those two shares of every round, go to the Wealth Fund until the market is usable again, so no SUI is ever stuck |
| Staking | Stake GTS, earn SUI (1% of every losing pot), split by stake weight: flexible 1x (withdraw any time), or locked for 7 days at 1.5x. New stake starts earning one hour after it is staked, so nobody can stake just before a large round and leave right after it. Warm-ups and lock ends are worked through by every draw (`stake_step`), so nothing depends on a keeper. Nothing is minted. With nobody staked, the stakers' share goes to the Wealth Fund. Until 2026-09-30 stakers also got the GTS the buyback bought; GTS yield earned before stays claimable |
| No reserve | GTS cannot be redeemed for SUI. Until the 2026-09-29 upgrade it could; the SUI left in the old reserve moved to the Wealth Fund |
| Draw | Anyone can draw a round (`settle_v3`, which also runs the buyback and the liquidity add) and is paid up to 0.008 SUI for it, about the gas of a draw, out of the round's Wealth Fund share only. The buyback, the liquidity share, the stakers' 1% and the 1% creator fee are never used for it. Rounds whose losing pot is under about 0.267 SUI pay less than that (their whole Wealth Fund share). GTStar's bots draw every round. The plain draw `settle_v2` touches no market; it pays nothing while the market works, and up to 0.004 SUI once the market has not been usable for 6 hours |
| Auto Mine | Live since 2026-10-01. A player sets SUI aside in the immutable `auto_vault` and picks a plan: Spread (5 random tiles), Sniper (1 random tile) or Hunter (the 5 tiles holding the least SUI, in the last 10 seconds before deposits close), at least 0.05 SUI a round. `game::auto_run`, open to anyone and called by the keeper every round, takes the player's per-round amount, pays 1% to the caller and 1% to the buyback and burn, and deploys the other 98% in the player's name, exactly like a deposit made by hand. SUI won goes back to the vault balance, mined GTS to the unrefined balance. Only the player can withdraw the balance, at any time; nothing can pause or block that |
| Randomness | `sui::random` (validator-generated, unbiasable) |

## Contract

Four packages.

[`contracts/supply_lock`](contracts/supply_lock), immutable (its upgrade key was destroyed on 2026-09-30, [transaction](https://suiscan.xyz/mainnet/tx/BtvDHVCVPHFSbNTZMDkjipQcNUvA2jPjSutizUYpzLmJ)): holds the GTS mint authority in a `CappedTreasury` that never lets the total ever minted pass 1,000,000. No function returns the mint authority or changes the limit, and no one can change this code, the owner included. The game mints round rewards through it (via `mint_limit` below) and can never go past the cap. Package `0xd4e17df7d3fe860fd7d3487a445ef7d96c23a52442469eb66bea5ffd38004e77`, CappedTreasury `0xd2629e21af2fa4f532f55e04f9caf19c1dec04719b7c1d3b84bed95bcf67cf28`.

[`contracts/mint_limit`](contracts/mint_limit), immutable (upgrade key destroyed on 2026-09-30, [transaction](https://suiscan.xyz/mainnet/tx/uCHVzcCZddjmQayJV9uLXWJPuKFzeSUSbz2dhRBusVk)): holds the only key to the supply lock (its `MinterCap`) in a `DailyLimiter` that lets at most 2,000 GTS through per UTC day. No function returns or lends the key or changes the limit. Package `0xc4c743f6b2c9c1d9cf729785fbf2393d2e8b7836300b349dbfed0e5321932c7c`, DailyLimiter `0x18f58d695534c18d28bc7d38f3f4a3433e0df0cdef6e223b07ab0c4264169753` (kept in the game board).

[`contracts/auto_vault`](contracts/auto_vault), immutable (upgrade key destroyed on 2026-10-01, [transaction](https://suiscan.xyz/mainnet/tx/4aCVbBytpAXZTK2TNJPnYnnuZGibrvoMnQt7yKYqSgJe)): the Auto Mine vault, package `0x781f524560af7086ce0530c39ffbd6d04ebf3d9597a22fba267ad033c81c7114`, Vault `0xcacceb6d9871af2797ddb46041c7ad3246af0c4654960ca40184b2188211ec3a`. Every player has an account in it, a SUI balance and a plan (strategy, SUI per round, rounds left, a balance to keep, a balance to stop at). Only the player can change the plan and withdraw, and `withdraw` has no condition other than the balance: no owner, admin, fee, setting or pause exists in the package. The game holds the single `PullCap`, with which it can take exactly a player's per-round amount, at most once every 20 seconds, only while their plan is on, has rounds left and stays above the balance they chose to keep. So a game upgrade could misuse per-round amounts of running plans, but can never block a withdrawal or take a balance.

[`contracts/gtstar`](contracts/gtstar), the game (upgradable by the owner):

| Module | Contents |
|---|---|
| `gts` | GTS coin type (redemption closed, no reserve). Its mint authority moved to `supply_lock` on 2026-09-30 |
| `game` | Rounds, the draw, fees, emission, the Wealth Fund, unrefined balances, Auto Mine (`auto_run`), the market step (buyback and burn, liquidity, `compound_fees`) |
| `staking` | GTS staking with SUI yield |

What the owner can still do with a game upgrade: change the rules, the fees and who receives GTS that is not mined yet (up to 2,000 GTS a day). What no one can do: mint past 1,000,000 GTS in total or 2,000 GTS in a UTC day.

During the launch phase the owner holds the `AdminCap` and the `UpgradeCap`, so settings and code can change at once and bugs can be fixed right away. Settings stay within limits written in the contract (Wealth Fund odds 1 in 100 to 1 in 1,000,000, 1-25 tiles, minimum deposit 0.0005-10 SUI, rounds 30 s to 1 h, withdraw fee up to 50%, emission only down: a lower reward, a cut up to 50% a step, shorter steps, and a pause of new deposits), each fee share it can set has its own cap (stakers 5%, Wealth Fund 10%), and the buyback and burn (3%) and liquidity (2%) shares are fixed. The buyback SUI and the liquidity SUI are spent only by the draw (`settle_v3`), on the Cetus GTS/SUI pool fixed in the code by its ID: the GTS bought is burned in the same transaction, the liquidity goes into a position locked in the game, and each draw's buys are limited to 2% above the reference price. No address can take either balance (`buyback_take` and `liquidity_take` are closed since 2026-10-01; before that the keeper wallet spent them under receipts the contract enforced). The `UpgradeCap` (policy 0, no timelock) can publish any new code, including code that moves SUI held by the game or the Wealth Fund. The `UpgradeCap` cannot touch the 1,000,000 cap or the 2,000 GTS a day limit: they live in the immutable `supply_lock` and `mint_limit` packages, outside the game package. Fixed in the current game code: the 1% creator fee, the 3% buyback and burn, the 2% liquidity share, the pool they are spent on and the 2% limit, what happens to that SUI if the market stops (to the Wealth Fund after 7 days), emission that can only go down, and no address can be blocked from playing, claiming or withdrawing. A pause only stops new deposits. `renounce` destroys the `AdminCap` for good; the plan is to give up both caps once the game is stable.

Deployed addresses and every upgrade transaction are in [`deployments/mainnet.json`](deployments/mainnet.json) and on the [Verify](https://minegts.fun/docs.html#verify) page.

## Repository

```
contracts/gtstar      GTS token, game and staking (Move); depends on the Cetus CLMM source for the market step
contracts/auto_vault  Auto Mine vault: players' balances and plans (Move, immutable)
contracts/supply_lock, contracts/mint_limit  the 1,000,000 cap and the 2,000 GTS a day limit (Move, immutable)
app/              Web app (static, non-custodial) and the keeper
scripts/          publish2.js (launch), admin2.mjs (settings), auto-deploy.mjs (Auto Mine), upgrade2.mjs (game upgrades)
deployments/      Live object IDs
legacy/           The first token and game (archived)
```

## Build and test

Requirements: [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install), Node.js 20+.

```sh
cd contracts/gtstar && sui move test      # 110 tests; the market tests run against the real Cetus CLMM code
cd contracts/auto_vault && sui move test
```

```sh
cd app
npm install
node build.js mainnet
node serve.js             # http://localhost:4173
```

## Settings

```sh
node scripts/admin2.mjs show
node scripts/admin2.mjs set odds=1000
```

## Keeper

Rounds are drawn by a permissionless call, `settle_v3`, which also runs the game's buyback and liquidity add (`app/keeper/draw.mjs`). The keeper (`app/keeper/`) runs every minute as a cron job on the host. Anyone can draw a round if the keeper is down, and is paid for it. The keeper holds no right the contract gives only to it: it also calls `compound_fees` once a day, which is open to anyone. Auto Mine plans are run the same way: `auto_run` is permissionless and pays its caller 1% of every deposit it makes (`app/keeper/auto.mjs` calls it every round).

## License

[Apache 2.0](LICENSE)
