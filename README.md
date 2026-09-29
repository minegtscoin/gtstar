# GTStar

**Mine GTS. Backed by SUI.**

GTStar is a fair-launch mining game on [Sui](https://sui.io). Every 60 seconds, players deploy SUI across a 5×5 board. One tile wins. Its miners split the pot, and **every** participant mines GTS by their share of the round. A slice of every pot flows into an on-chain SUI reserve that backs every GTS.

- App: https://minegts.fun
- Docs: https://minegts.fun/docs.html
- X: https://x.com/MineGTS1
- Telegram: https://t.me/MineGTS

> **Relaunch, 2026-09-29.** GTStar relaunched with a new GTS token and a new game. The first token and game are archived in [`legacy/`](legacy); their reserve stays immutable, so old GTS can still be redeemed there.

## Overview

| | |
|---|---|
| Max supply | 1,000,000 GTS, hard cap in the contract |
| Premine / team / presale | None |
| Emission | 1 GTS per round, shared by everyone in the round by SUI deployed (full reward from 1 SUI in the round, less for smaller rounds). Every 15,658 rounds the reward drops 1.425%. The cut follows rounds, not GTS mined, so the 1,000,000 cap is a ceiling: full rounds every time would mint about 1,099,000, and rounds below 1 SUI mint less, so the final supply can end below 1,000,000. Counted by rounds played, not by date |
| Losing pot | Up to 90% winners · 4% reserve · 3% stakers · 2% Wealth Fund · 1% creator. A winner keeps the part of their own round deposit that sat on the winning tile (0.01 SUI on each of 25 tiles keeps 1/25); the rest goes to the reserve. One miner per wallet per round |
| Wealth Fund | 2% of every losing pot, plus 19.5% when no one is on the winning tile. Every round has a 1 in 100 chance to pay the whole fund to one ticket holder. Tickets = the fees a player paid on SUI they lost since the last payout (10% of it), so extra wallets give no extra tickets; bots get none |
| Unrefined GTS | Mined GTS waits in your unrefined balance. Withdrawing costs 10%, shared among everyone still holding |
| Staking | Stake GTS, earn SUI (3% of every losing pot). Flexible 1x or 7-day lock 1.5x. Nothing is minted |
| Reserve | Burn GTS at any time for a pro-rata share of the SUI reserve |
| Draw | Anyone can draw a round and is paid up to 0.005 SUI for it. The keeper draws every round |
| Randomness | `sui::random` (validator-generated, unbiasable) |

## Contract

One package, [`contracts/gtstar`](contracts/gtstar):

| Module | Contents |
|---|---|
| `gts` | GTS coin, the 1,000,000 cap, the SUI reserve and redemption |
| `game` | Rounds, the draw, fees, emission, the Wealth Fund, unrefined balances |
| `staking` | GTS staking with SUI yield |

During the launch phase the owner holds the `AdminCap` and the `UpgradeCap`, so settings and code can change at once and bugs can be fixed right away. Settings stay within limits written in the contract, but fee shares are capped only in total, and `take_buyback` pays the buyback share to the owner with no on-chain buy-and-burn. The `UpgradeCap` (policy 0, no timelock) can publish any new code, including code that moves reserve SUI. Fixed: the 1% creator fee, the 1,000,000 cap, and no address can be blocked from playing, claiming or withdrawing. A pause only stops new deposits. `renounce` destroys the `AdminCap` for good; the plan is to give up both caps once the game is stable.

Deployed addresses and every upgrade transaction are in [`deployments/mainnet.json`](deployments/mainnet.json) and on the [Verify](https://minegts.fun/docs.html#verify) page.

## Repository

```
contracts/gtstar  GTS token, game and staking (Move)
app/              Web app (static, non-custodial), the keeper and bots, the X poster
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
node scripts/admin2.mjs set odds=1000 reserve=400
```

## Keeper

Rounds are drawn by a permissionless `settle` call. The keeper (`app/keeper/`) runs every minute as a cron job on the host. Anyone can draw a round if the keeper is down, and is paid for it.

## License

[Apache 2.0](LICENSE)
