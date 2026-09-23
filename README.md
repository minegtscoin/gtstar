# GTStar

**Mine GTS. Backed by SUI.**

GTStar is a fair-launch mining game on [Sui](https://sui.io). Every 60 seconds, players deploy SUI across a 5×5 board. One tile wins. Its miners split the pot, and **every** participant mines GTS by their share of the round. A slice of every pot flows into an on-chain SUI reserve that backs every GTS.

- App: https://minegts.fun
- Docs and whitepaper: https://minegts.fun/docs.html

## Overview

| | |
|---|---|
| Max supply | 571,897 GTS: 7 halving periods of 262,000 rounds |
| Premine / team / presale | None |
| Emission | 1 GTS per round to miners, +10% to stakers, halving every 262,000 rounds (by rounds played, not by date), ending after round 1,834,000 |
| Losing pot | 95% winners · 4% reserve · 1% creator (no one on the winning tile: the 95% rolls into the Motherlode) |
| Motherlode | Every round with a winner: 1 in 100 chance to pay the whole Motherlode to the winning tile |
| Reserve | Burn GTS at any time for a pro-rata share of the SUI reserve |
| Staking | Stake GTS, earn GTS. No lock-up. Rewards stream over 7 days |
| Randomness | `sui::random` (validator-generated, unbiasable) |

## Contracts

The protocol is split so that the economics are locked while the product can still improve.

| Package | Path | Contents | Upgradeable |
|---|---|---|---|
| `gts_token` | [`contracts/token`](contracts/token) | GTS coin, emission ceiling, SUI reserve, redemption | **No**, immutable at launch |
| `gtstar` | [`contracts/game`](contracts/game) | Game rounds, fees, staking | Yes, for fixes and improvements |

The token package only mints through a single `MinterCap` held by the game, and never above the published ceiling (1.1 GTS per minute, halving every 6 months, frozen from 2030). Burned GTS is never re-minted. No game upgrade can change this. The game's round-based schedule always stays under that ceiling.

Deployed addresses are listed in [`deployments/`](deployments) and on the [Verify](https://minegts.fun/docs.html#verify) page.

## Repository

```
contracts/token   Immutable token package (Move)
contracts/game    Game and staking package (Move)
app/              Web app (static, non-custodial) and the keeper
bot/              Standalone keeper that settles rounds
scripts/          Publish and launch script
deployments/      Object IDs per network
```

## Build and test

Requirements: [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install), Node.js 20+.

```sh
cd contracts/token && sui move test
cd contracts/game && sui move test
```

```sh
cd app
npm install
node build.js testnet     # or mainnet
node serve.js             # http://localhost:4173
```

## Launch

```sh
node scripts/publish.js mainnet
```

The script publishes both packages, installs the game's minting right, starts the emission clock, freezes the token metadata and makes the token package immutable.

## Keeper

Rounds are settled by a permissionless `settle` call. The keeper runs every minute as a cron job on the host (`app/keeper/`) (or locally with `node bot/crank.js mainnet`). Anyone can settle a round if the keeper is down.

## Security

- 21 Move unit tests across both packages: emission ceiling, hard cap, burn accounting, redemption floor, pot solvency, double claims, freeze window, payment checks, minimum deposit, early settlement, install once, streamed staking, sniping resistance.
- End-to-end tests against a live network: `node app/e2e.mjs testnet`.

## License

[Apache 2.0](LICENSE)
