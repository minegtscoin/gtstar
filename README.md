# GTStar

**Mine GTS. Win SUI.**

GTStar is a fair-launch mining game on [Sui](https://sui.io). Every 60 seconds, players deploy SUI across a 5×5 board. One tile wins. Its miners split the pot, and every SUI deployed in the round mines GTS, win or lose. GTS has no SUI reserve: its price is set by the market.

- App: https://minegts.fun
- Docs: https://minegts.fun/docs.html
- X: https://x.com/MineGTS1
- Telegram: https://t.me/MineGTS

> **Relaunch, 2026-09-29.** GTStar relaunched with a new GTS token and a new game. The first token and game are archived in [`legacy/`](legacy); their reserve stays immutable, so old GTS (the first token) can still be redeemed there.

## Overview

| | |
|---|---|
| Max supply | 1,000,000 GTS, hard cap in the contract |
| Premine / team / presale | None |
| Emission | 1 GTS per round, shared by SUI deployed, win or lose (full reward from 1 SUI in the round, less for smaller rounds: 0.25 SUI mines 0.25 GTS). Every 15,658 rounds the reward drops 1.425%. The cut follows rounds, not GTS mined, so the 1,000,000 cap is a ceiling: full rounds every time would mint about 1,099,000, and rounds below 1 SUI mint less, so the final supply can end below 1,000,000. Counted by rounds played, not by date |
| Losing pot | 90% winners · 4% Wealth Fund · 3% buyback (GTS bought on Cetus and burned) · 2% stakers · 1% creator. Winners split it by their stake on the winning tile; a spread deposit keeps only the part of its share matching the part of its round deposit on the winning tile (fair split), the rest goes to the Wealth Fund. One miner per wallet per round |
| Wealth Fund | 4% of every losing pot, plus what spread deposits do not keep, and the whole pot less fees when no one is on the winning tile. Every round has a 1 in 500 chance to pay the whole fund to one ticket holder. Tickets = the fees a player paid on SUI they lost since the last payout (10% of it), so extra wallets give no extra tickets; bots get none |
| Unrefined GTS | Mined GTS waits in your unrefined balance. Withdrawing is free 7 days after your last withdrawal; before that the fee falls from 10% to 0 and is burned |
| Staking | Stake GTS, earn SUI (2% of every losing pot). Withdraw any time. Nothing is minted |
| No reserve | GTS cannot be redeemed for SUI. Until the 2026-09-29 upgrade it could; the SUI left in the old reserve moved to the Wealth Fund |
| Draw | Anyone can draw a round and is paid up to 0.005 SUI for it. The keeper draws every round |
| Randomness | `sui::random` (validator-generated, unbiasable) |

## Contract

One package, [`contracts/gtstar`](contracts/gtstar):

| Module | Contents |
|---|---|
| `gts` | GTS coin and the 1,000,000 cap (redemption closed, no reserve) |
| `game` | Rounds, the draw, fees, emission, the Wealth Fund, unrefined balances |
| `staking` | GTS staking with SUI yield |

During the launch phase the owner holds the `AdminCap` and the `UpgradeCap`, so settings and code can change at once and bugs can be fixed right away. Settings stay within limits written in the contract, each fee share has its own cap, and the buyback SUI can only be spent by the keeper in a transaction that burns the GTS it bought (`buyback_take` / `buyback_burn`). The `UpgradeCap` (policy 0, no timelock) can publish any new code, including code that moves SUI held by the game or the Wealth Fund. Fixed: the 1% creator fee, the 1,000,000 cap, and no address can be blocked from playing, claiming or withdrawing. A pause only stops new deposits. `renounce` destroys the `AdminCap` for good; the plan is to give up both caps once the game is stable.

Deployed addresses and every upgrade transaction are in [`deployments/mainnet.json`](deployments/mainnet.json) and on the [Verify](https://minegts.fun/docs.html#verify) page.

## Repository

```
contracts/gtstar  GTS token, game and staking (Move)
app/              Web app (static, non-custodial) and the keeper
scripts/          publish2.js (launch), admin2.mjs (settings)
deployments/      Live object IDs
legacy/           The first token and game (archived)
```

## Build and test

Requirements: [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install), Node.js 20+.

```sh
cd contracts/gtstar && sui move test
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
node scripts/admin2.mjs set odds=1000 buyback=100
```

## Keeper

Rounds are drawn by a permissionless `settle` call. The keeper (`app/keeper/`) runs every minute as a cron job on the host. Anyone can draw a round if the keeper is down, and is paid for it.

## License

[Apache 2.0](LICENSE)
