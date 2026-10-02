# GTStar

**Mine GTS. Win SUI.**

GTStar is a fair-launch mining game on [Sui](https://sui.io). Every 60 seconds, players deploy SUI across a 5×5 board. One tile wins and its miners split the pot. Every SUI deployed mines GTS, win or lose.

Only **31,316 GTS** can ever be mined. The rules are locked on-chain: no one can change them, the creator included.

- Play: https://minegts.fun
- Docs: https://minegts.fun/docs.html
- X: https://x.com/MineGTS1
- Telegram: https://t.me/MineGTS

## Why GTStar

- **Fair launch.** No premine, no team tokens, no presale. Every GTS in circulation was mined by a player.
- **Scarce by code.** The mining reward is cut in half as GTS is mined, so 31,316 GTS is all there will ever be.
- **Bought back and burned every round.** 3% of every losing pot buys GTS on the market and burns it, inside the draw itself.
- **Holders earn SUI.** 3% of every losing pot is paid in SUI to GTS stakers. Nothing is minted for it.
- **Liquidity that only grows.** 2% of every losing pot goes into the GTS/SUI pool, in positions held by the game. The game has no function to take them out.
- **Locked for good.** The settings key is destroyed and the code cannot change. Nobody can change the fees, mint extra GTS, pause the game or take funds out of it.
- **Provably random.** Winners are drawn with Sui's on-chain randomness.
- **Non-custodial.** The app holds no keys and no funds. Every action is signed in the player's own wallet.

## How a round works

| | |
|---|---|
| Round | Starts with its first deposit and lasts 60 seconds. Deposits close 5 seconds before the end |
| Deposit | Up to 5 of the 25 tiles per wallet, minimum 0.0005 SUI per tile |
| Draw | One winning tile, drawn with `sui::random`. Anyone can draw a round that has ended, and is paid 1% of its losing pot |
| Winners | Get their stake on the winning tile back, plus 90% of the SUI on the other 24 tiles, split by stake |
| Mining | Every SUI deployed mines GTS, win or lose. A round mints the full reward when it holds 7 SUI or more, and a matching part below that |
| Wealth Fund | A SUI jackpot. When no one is on the winning tile, the pot of that round goes into it. Every round has a 1 in 250 chance to pay the whole fund to one ticket holder. Tickets are the fees a player paid on SUI they lost |

## The token

| | |
|---|---|
| Maximum supply | 31,316 GTS |
| Premine, team, presale | None |
| Source | Mining only |
| Reward | 1 GTS for a full round, cut in half at 15,658 GTS mined, then after 7,829 more, then 3,914.5 more, and so on |
| Halving | By GTS mined, not by time. A small round moves it only by the GTS it mined, so empty rounds cannot hurry it |
| Unrefined GTS | Mined GTS waits in the player's unrefined balance. Withdrawing is free after 7 days; before that the fee falls from 10% to 0. Half the fee is burned, half goes to everyone still holding |
| Staking | Stake GTS, earn SUI. No lock: a stake can leave at any time. New stake starts earning after one hour |
| Price | Set by the market. GTS has no reserve and is not redeemable for SUI |

### Where the losing pot goes

| Destination | Share |
|---|---|
| Winners | 90% |
| Buyback and burn | 3% |
| GTS stakers, in SUI | 3% |
| Liquidity, locked in the game | 2% |
| Whoever draws the round | 1% |
| Creator | 1% |

Fees come only from the losing pot, never from a winner's stake.

### Buyback and liquidity

The game runs both by itself, inside the draw, on the Cetus GTS/SUI pool. No wallet holds that SUI and no function lets any address take it.

- **Buyback.** Once 0.005 SUI is saved, the draw buys GTS and burns it in the same transaction.
- **Liquidity.** Once 0.05 SUI is saved, the draw buys GTS with 49% of it and adds the GTS with the matching SUI to a position held by the game. `compound_fees` puts the positions' trading fees back into the pool. Anyone can add to the locked liquidity with `lock_position` or `give_liquidity`.
- **Price guard.** One draw's buys can lift the price at most 2% above the price after the previous draw.
- **If Cetus stops.** Rounds are drawn without the market step and the SUI is saved. After 7 days without a usable market it goes to the Wealth Fund, so nothing is ever stuck.

## Locked on-chain

- **The settings.** The `AdminCap` is destroyed. The fees, the Wealth Fund odds, the minimum deposit, the round length, the 5-tile limit and the withdraw fee are fixed. The game can never be paused.
- **The code.** The `UpgradeCap` is restricted for good to dependency-only upgrades (policy 192). The chain refuses any upgrade that changes the game's modules.
- **The supply.** The halving is part of the locked code. The right to mint GTS sits in immutable contracts, and only the game can use it.
- **The token.** The GTS coin metadata is frozen.

Proof: [the lock transaction](https://suiscan.xyz/mainnet/tx/7TF5yhZr4Q9pLDyUMnF2ZzpxqEu2qLcoK7ycDsrtTjAE).

The one thing the creator address `0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e` can do: link the game to a newer version of a package it uses. That exists for Cetus, so the buyback and the liquidity add keep running after a Cetus upgrade. It cannot change the rules or the fees, take SUI, GTS or liquidity out of the game, or pause it.

The creator fee, 1% of every losing pot, is paid to `0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b`. It is fixed in the code like everything else.

## Verify it yourself

The source in this repository compiles to exactly the code running on Sui mainnet. With the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install):

```sh
cd contracts/gtstar && sui client verify-source
cd contracts/supply_lock && sui client verify-source
cd contracts/mint_limit && sui client verify-source
```

| | |
|---|---|
| GTS coin type | `0x2beecdcba43f4ee412ce886216e0e8bb5d48486fa59a43222432f9f56c0592f8::gts::GTS` |
| Game package | `0xfeccc4daae2f1682db323cbdceb4c8c6904034f20b04497a93e12e7977c6b0a8` |
| Game board | `0xc171dcb3ebba55d0d186140f43b09ca987fef92fb02c49df921f08c4c1e7548b` |
| GTS/SUI pool (Cetus) | `0x0628902c5acd5b5755c9b1a6494e925d0c5327177486b5e3b25d0e9b0211de71` |
| Upgrade key | `0xe94fdc95c476e7b0fdc89c881ab5e8413a5745f31586ef8edab95f2a38d922b1` |

All addresses are in [`deployments/mainnet.json`](deployments/mainnet.json) and on the [Verify](https://minegts.fun/docs.html#verify) page.

## Contracts

| Package | Contents |
|---|---|
| [`contracts/gtstar`](contracts/gtstar) | The GTS coin, the game (rounds, the draw, fees, the halving, the Wealth Fund, buyback and liquidity) and staking |
| [`contracts/supply_lock`](contracts/supply_lock) | Immutable. Holds the only right to mint GTS |
| [`contracts/mint_limit`](contracts/mint_limit) | Immutable. At most 2,000 GTS can be minted per UTC day |

## Build and test

Requirements: [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install), Node.js 20+.

```sh
cd contracts/gtstar && sui move test      # 100 tests; the market tests run against the real Cetus CLMM code
```

```sh
cd app
npm install
node build.js mainnet
node serve.js             # http://localhost:4173
```

## Runs by itself

A round starts with a player's deposit and is drawn by a call anyone can make, which pays its caller 1% of the losing pot. The game needs no operator, and this site is only a window: anyone can play, draw and claim straight from the contract.

GTStar runs two bots, with no right the contract gives only to them: a keeper (`app/keeper/`) that draws rounds, and a player bot that joins rounds players are already in, with its own SUI.

## Risk

GTStar is a game of chance. Tiles that do not win lose their deposit, the price of GTS can fall, and a locked contract cannot be patched if a bug is found. Only play with what you can afford to lose.

## License

[Apache 2.0](LICENSE)
