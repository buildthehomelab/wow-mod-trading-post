# mod-trading-post

**Retail's Trading Post and Traveler's Log** for AzerothCore (3.3.5a).

Every calendar month brings a theme, a shelf of mounts and companions, and a list of things to do.
Doing them earns **Trader's Tender**, an account-wide currency that buys what's on the shelf.

## How it works

- **Traveler's Log.** Each month lists 18 activities: kills, quests, dungeon and raid bosses,
  crafting, gathering, fishing, battlegrounds and more. Progress counts for the whole account, and
  bots don't count. 1,000 points pay 500 Tender and the month's bonus reward. A month offers more
  than 1,000 points, so nobody has to do all of it. `/tlog` opens it; with the Journal addon of
  [mod-forever-journal](https://github.com/buildthehomelab/wow-mod-forever-journal) it's a tab there.
- **Collector's Cache.** 500 Tender once a month per account, taken at a proprietor.
- **Trading Post.** A proprietor by the auction house in Stormwind and in Orgrimmar opens a window
  with the month's goods and a model of each. What's left at the end of the month goes back in the
  vault until its month comes round next year.
- **Freezing.** An account can freeze one of the month's goods. It stays on sale for that account
  until it's bought or thawed.

Everything goes by the server's local calendar. Numbers are settings, in
`conf/mod_trading_post.conf.dist`.

## What it works with, if you have it

All optional:

- **mod-accountwide-mounts / mod-accountwide-pets:** purchases go to the whole account. Without
  them they're mailed to the buyer.
- **mod-individual-progression:** goods with a `phase` stay locked until a character of the account
  reaches it. The generated data puts flying mounts at phase 8.
- **mod-challenges:** Self-Found characters can't buy.
- **DragonUI:** the windows wear its look, and Tender gets a row in its Currency tab.

The generated stock sells items from an item library that isn't part of this module. Rows for items
your server doesn't have are skipped at startup; fill `mod_trading_post_stock` with your own, or
remake it with `tools/build_data.py`, which documents its inputs.

## Install

```bash
cd modules
git clone https://github.com/buildthehomelab/wow-mod-trading-post.git mod-trading-post
```

Re-run CMake, rebuild, and restart. The SQL applies itself. Copy `addon/TradingPost` to the client's
`Interface/AddOns`. Without the addon a proprietor only says that it's needed.

## Commands

| Command | Who | What |
|---|---|---|
| `.tradingpost` | anyone | your account's Tender |
| `.tradingpost adjust <account> <n>` | admin | add or, with a minus, take Tender |
| `.tradingpost reload` | admin | read config, stock and activities again |

## Tables

| Database | Table | Holds |
|---|---|---|
| world | `mod_trading_post_theme` | a month's name, description and bonus item |
| world | `mod_trading_post_stock` | goods by month: price, phase, order |
| world | `mod_trading_post_activity` | activities; theme 0 means every month |
| characters | `mod_trading_post_wallet`, `_ledger` | Tender, and every change |
| characters | `mod_trading_post_month`, `_progress` | an account's claims and activity |
| characters | `mod_trading_post_purchase`, `_frozen` | what it bought and holds over |

Activity types are listed in `src/TradingPost.h`.

## Uninstall

Remove the module and run the two files in `data/sql/uninstall` by hand. AzerothCore doesn't apply
them by itself. Purchased mounts and companions stay known by the characters that have them.

## IDs

Creature entries and spawn guids 9509000-9509001, gossip menu and npc text 9509000. The range to
9509099 is kept free for the module. Stock item 37711, an unobtainable test token, is renamed to
stand for Tender in DragonUI's Currency tab.

## Developing

```bash
python3 tools/build_data.py
lua tools/addon_smoke_test.lua addon/TradingPost
```

## Patch Notes: Trading Post

Category: Features

- **The Trading Post is open.** Find a proprietor by the auction house in Stormwind or Orgrimmar.
  Every month brings a new theme and a new shelf of mounts and companions, each with a model to
  turn around before you buy.
- **The Traveler's Log** lists 18 things to do each month, from quests and bosses to crafting,
  fishing and battlegrounds. Everything your account does counts. Reach 1,000 points for 500
  Trader's Tender and the month's bonus mount. Open it with /tlog or from the Journal.
- **The Collector's Cache** holds another 500 Tender every month. Just visit a proprietor to take it.
- **Freeze** one item you can't afford yet, and it stays on sale for you until you buy it.
- Your Tender shows in the Currency tab.
- Purchases belong to your whole account. Self-Found characters can't earn or spend Tender.

## License

MIT
