# GTStar

**Mine GTS. Win SUI.**

GTStar is a fair-launch mining game on [Sui](https://sui.io). Every 60 seconds, players deploy SUI across a 5×5 board. One tile wins. Its miners split the pot, and every SUI deployed in the round mines GTS, win or lose. GTS has no SUI reserve: its price is set by the market.

GTS is built to hold value: a mining reward that is cut in half as GTS is mined (31,316 GTS at most), a round that needs 7 SUI to mint its full reward, 3% of every losing pot spent on buying GTS and burning it, 3% paid in SUI to GTS stakers, and 2% added to liquidity in positions held by the game, which has no function to take them out. None of that sets the price.

- App: https://minegts.fun
- Docs: https://minegts.fun/docs.html (the short version; this README is the technical reference)
- X: https://x.com/MineGTS1
- Telegram: https://t.me/MineGTS

> **Locked, 2026-10-02.** The game below is final and locked: its settings key was destroyed and its code can no longer change ([transaction](https://suiscan.xyz/mainnet/tx/7TF5yhZr4Q9pLDyUMnF2ZzpxqEu2qLcoK7ycDsrtTjAE)). See [What is locked, and what is not](#what-is-locked-and-what-is-not).

> **Relaunch, 2026-09-29.** GTStar relaunched with a new GTS token and a new game. The first token and game are archived in [`legacy/`](legacy); their reserve stays immutable, so old GTS (the first token) can still be redeemed there.

## Overview

| | |
|---|---|
| Premine / team / presale | None |
| Emission | A round mints up to the current reward, shared by SUI deployed, win or lose. The full reward needs 7 SUI in the round; a smaller round mints the matching part (1 SUI mines about 0.143 GTS until the first halving). No other source of GTS |
| Halving | By GTS mined, not by time or by rounds. The reward starts at 1 GTS and is cut in half each time a step has mined what 15,658 full rounds mint at the current reward: at 15,658 GTS mined in total, then after 7,829 more, then 3,914.5 more, and so on. 31,316 GTS is the most that can ever be mined. A small round moves the halving only by the GTS it mined, so empty rounds cannot hurry it. Fixed in the code: `set_emission` is closed |
| Sealed limits | 1,000,000 GTS in total and 2,000 GTS per UTC day, in two immutable contracts (`supply_lock`, `mint_limit`). Both sit far above what the halving allows. If the daily limit is ever reached, a claim still pays its SUI at once and the GTS is owed to the player (`claim_owed`) |
| Losing pot | 90% winners · 3% buyback and burn · 3% GTS stakers (in SUI) · 2% liquidity · 1% whoever draws the round · 1% creator |
| A round no one wins | With no one on the winning tile, the winners' 90% goes to the Wealth Fund |
| Wealth Fund | A SUI jackpot. No fee pays for it: it receives the pot of every round no one wins, the stakers' share while nobody is staked, what the plain draw does not pay its caller, and the market shares after 7 days without a market. Every round has a 1 in 250 chance to pay the whole fund to one ticket holder. Tickets = the fees a player paid on SUI they lost since the last payout |
| Draw | Anyone can draw a round that has ended. `settle_v3` runs the market step and pays its caller the whole 1%. The plain draw `settle_v2` (no market step) pays nothing while the market works and half of the 1% once the market has not been usable for 6 hours. `entry` and not `public`, so a draw cannot be composed with a check of its outcome |
| Buyback and liquidity | Run by the game itself, inside the draw, on the Cetus GTS/SUI pool fixed in the code by its ID. The buyback runs once 0.005 SUI is saved: the GTS bought is burned in the same transaction. The liquidity add runs once 0.05 SUI is saved: 49% buys GTS, and the GTS with the matching SUI goes into a position held by the game. A draw's buys may lift the price at most 2% above the reference price (the price after the previous draw's market step). No function lets any address take either balance or a position. `compound_fees` (anyone) puts the positions' trading fees back into the pool; `lock_position` and `give_liquidity` (anyone) add to the locked liquidity |
| If Cetus stops or upgrades | A paused pool is skipped. If Cetus moves to a version the game is not linked to, `settle_v3` aborts and rounds are drawn by `settle_v2`; the SUI for the market is saved, and after 7 days without a usable market it goes to the Wealth Fund, with those two shares of every round, until the market works again. The game can be linked to the new Cetus version with a dependency-only upgrade (`scripts/relink.mjs`) |
| Unrefined GTS | Mined GTS waits in the player's unrefined balance. Withdrawing is free once their 7-day clock has run out; before that the fee falls from 10% to 0: half is burned and half is shared by everyone still holding unrefined GTS. The clock is weighted by amount |
| Staking | Stake GTS, earn SUI (3% of every losing pot), split by GTS staked. No lock: a stake can leave at any time. New stake starts earning one hour after it is staked, so nobody can stake just before a large round and leave right after it; the draw starts it earning by itself. Nothing is minted for staking |
| Limits | 5 tiles per wallet a round, minimum 0.0005 SUI per tile, deposits close 5 seconds before the end |
| No reserve | GTS cannot be redeemed for SUI |
| Closed | Auto Mine (automatic rounds from a vault balance) and the 7-day staking lock at 1.5x ran until 2026-10-02 and are closed in the code. `auto_run` only claims an automatic round played before; a stake made under the lock counts 1x and can leave at any time. The immutable `auto_vault` still lets its one past user withdraw |
| Randomness | `sui::random` (validator-generated, unbiasable) |

## Contracts

[`contracts/gtstar`](contracts/gtstar), the game:

| Module | Contents |
|---|---|
| `gts` | GTS coin type (redemption closed, no reserve). Its mint authority moved to `supply_lock` on 2026-09-30 |
| `game` | Rounds, the draw, fees, the halving, the Wealth Fund, unrefined balances, the market step (buyback and burn, liquidity, `compound_fees`) |
| `staking` | GTS staking with SUI yield |

[`contracts/supply_lock`](contracts/supply_lock), immutable (its upgrade key was destroyed on 2026-09-30, [transaction](https://suiscan.xyz/mainnet/tx/BtvDHVCVPHFSbNTZMDkjipQcNUvA2jPjSutizUYpzLmJ)): holds the GTS mint authority in a `CappedTreasury` that never mints past 1,000,000. That is an older outer limit: the halving in the game stops at 31,316.

[`contracts/mint_limit`](contracts/mint_limit), immutable (upgrade key destroyed on 2026-09-30, [transaction](https://suiscan.xyz/mainnet/tx/uCHVzcCZddjmQayJV9uLXWJPuKFzeSUSbz2dhRBusVk)): holds the only key to the supply lock in a `DailyLimiter` that mints at most 2,000 GTS per UTC day.

[`contracts/auto_vault`](contracts/auto_vault), immutable (upgrade key destroyed on 2026-10-01, [transaction](https://suiscan.xyz/mainnet/tx/4aCVbBytpAXZTK2TNJPnYnnuZGibrvoMnQt7yKYqSgJe)): the vault of the closed Auto Mine. Only a player can withdraw their own balance.

## What is locked, and what is not

Locked for good on 2026-10-02, in one [transaction](https://suiscan.xyz/mainnet/tx/7TF5yhZr4Q9pLDyUMnF2ZzpxqEu2qLcoK7ycDsrtTjAE) (`scripts/lock.mjs`):

- **The settings.** `game::renounce` destroyed the `AdminCap`. Stakers 3%, the draw share 1%, Wealth Fund odds 1 in 250, 5 tiles, minimum deposit 0.0005 SUI, 60-second rounds, withdraw fee 10%: all fixed as they are. The game can never be paused.
- **The code.** `sui::package::only_dep_upgrades` restricted the `UpgradeCap` (`0xe94fdc95c476e7b0fdc89c881ab5e8413a5745f31586ef8edab95f2a38d922b1`, policy 192) to dependency-only upgrades. The restriction cannot be loosened. The chain refuses any upgrade whose modules differ from the ones published: `authorize_upgrade` with a looser policy aborts with `ETooPermissive`.
- **The token.** The GTS `CoinMetadata` is frozen.
- **The supply.** The halving is part of the locked code (`set_emission` is closed): 31,316 GTS at most. The older 1,000,000 cap and 2,000 GTS a day limit of the two immutable packages stay above it.

What the owner address `0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e` can still do, and nothing else: link the game to a newer version of a package it uses (`scripts/relink.mjs`). That exists for Cetus: after a Cetus upgrade the market step needs the new link. It cannot change the rules or the fees, take SUI, GTS or liquidity out of the game, or pause it. Only the publisher of a package can publish a new version of it, so the game cannot be pointed at a fake Cetus.

What follows from a lock: a bug in the game's code cannot be fixed, and the settings stay in SUI terms whatever SUI is worth.

The creator fee, 1% of every losing pot, is paid to `0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b` (`withdraw_dev_fees`, callable by anyone, pays only that address).

Deployed addresses and every upgrade transaction are in [`deployments/mainnet.json`](deployments/mainnet.json) and on the [Verify](https://minegts.fun/docs.html#verify) page.

## Repository

```
contracts/gtstar      GTS token, game and staking (Move); depends on the Cetus CLMM source for the market step
contracts/supply_lock, contracts/mint_limit  the older outer limits: 1,000,000 GTS in total, 2,000 GTS a day (Move, immutable)
contracts/auto_vault  the vault of the closed Auto Mine (Move, immutable)
app/              Web app (static, non-custodial), the keeper, and e2e2.mjs (one live round, checked to the mist)
scripts/          relink.mjs (link the game to a new Cetus version); lock.mjs, upgrade2.mjs and admin2.mjs were used before the lock
deployments/      Live object IDs and every on-chain proof
legacy/           The first token and game (archived)
```

## Build and test

Requirements: [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install), Node.js 20+.

```sh
cd contracts/gtstar && sui move test      # 100 tests; the market tests run against the real Cetus CLMM code
cd contracts/auto_vault && sui move test
```

```sh
cd app
npm install
node build.js mainnet
node serve.js             # http://localhost:4173
```

## Running without anyone

A round starts with a player's deposit and is drawn by a permissionless call that pays its caller 1% of the losing pot, so the game needs no operator. A round that pays less than a draw costs in gas (about 0.005 SUI) is drawn by the next player who wants to play: the app's Deploy button draws it first, then deploys.

GTStar also runs a keeper (`app/keeper/`, a cron job) that draws every round, small ones at a loss, and calls `compound_fees` once a day. A second bot (`app/keeper/player.mjs`) joins rounds that players are already in, with its own SUI; no GTStar bot opens a round by itself. Neither holds a right the contract gives only to it.

## If Cetus upgrades

```sh
node scripts/relink.mjs          # dry run: which package versions would change, and whether the chain accepts it
GO=1 node scripts/relink.mjs     # send it
```

It sends the game's own modules, read from the chain and unchanged, with the new versions of the packages it uses. The chain refuses anything else from this upgrade key.

## License

[Apache 2.0](LICENSE)
