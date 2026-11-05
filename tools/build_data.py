#!/usr/bin/env python3
"""Builds data/sql/db-world/mod_trading_post_world.sql.

The twelve monthly themes, each with its stock and its bonus reward, and the Traveler's Log activities.
Stock comes from data/stock.tsv. That file is committed, so the SQL can be rebuilt anywhere; make it
afresh with --stock, which reads a retail Mount.csv and BattlePetSpecies.csv export and keeps what
retail sells at the Trading Post, the item library has and no other shop sells:

    build_data.py --stock --db2 <dir> --library <collection.tsv> --exclude <shop.tsv> [--exclude ...]
    build_data.py
"""
import argparse
import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STOCK = ROOT / "data" / "stock.tsv"
SQL = ROOT / "data" / "sql" / "db-world" / "mod_trading_post_world.sql"

NPC_ALLIANCE = 9509000
NPC_HORDE = 9509001
TEXT_NO_ADDON = 9509000
CURRENCY_ITEM = 37711   # "Currency Token Test Token 1": in every client, obtainable nowhere
CURRENCY_NAME = "Trader's Tender"
CURRENCY_TEXT = "Earned from the Traveler's Log and the Collector's Cache. Spent at the Trading Post. Shared by your whole account."

PRICE_GROUND = 600
PRICE_FLYER = 800
PRICE_PET = 250
FLYER_PHASE = 8     # flying opens with The Burning Crusade

# calendar month -> name, description
THEMES = [
    ("Deepwinter Bazaar", "Warm coats and sure feet for the coldest month."),
    ("Hearts and Hooves", "Companions to keep close and mounts worth showing off."),
    ("Spring Thaw", "Everything the melting snow turned up."),
    ("Wild Wanderers", "Creatures from the far edges of the map."),
    ("Bloom and Burrow", "Bright colours for a bright month."),
    ("Midsummer Market", "Goods for long days and short tempers."),
    ("Tides and Trade", "Cargo fresh off the boats."),
    ("Harvest Caravan", "The caravans come in heavy this time of year."),
    ("Autumn Hunt", "Trophies for those who like to track their own."),
    ("Shadowed Stalls", "The stock the proprietor only shows after dark."),
    ("Ember and Ash", "Things that are better kept at a distance."),
    ("Year's End Vault", "The back room, opened up before the books close."),
]

# Activity types, as in src/TradingPost.h.
KILL, KILL_ELITE, KILL_RARE, QUEST, DUNGEON_BOSS, RAID_BOSS, GATHER, FISH, CRAFT, BG_PLAY, BG_WIN, LEVEL, \
    ACHIEVEMENT, PVP_KILL = range(1, 15)

BEAST, DRAGONKIN, DEMON, ELEMENTAL, GIANT, UNDEAD, HUMANOID = 1, 2, 3, 4, 5, 6, 7
HERBALISM, MINING, SKINNING = 182, 186, 393

# Every month: id, type, target, amount, points, name, description.
#
# Progress is stored by id, so an id keeps its meaning for good. The small steps come first: the log
# should tick over within minutes of normal play and never ask for a long haul. The bigger steps of
# a kind stay on the list for whoever gets there anyway. Nothing here is a must: the list offers well
# over the points the log asks for, raids and PvP included but not needed.
ACTIVITIES = [
    (9, KILL, 0, 25, 25, "Road Work", "Defeat 25 enemies that would give you experience."),
    (10, KILL, 0, 100, 50, "Roadside Menace", "Defeat 100 enemies that would give you experience."),
    (1, KILL, 0, 200, 75, "Keeping the Roads Clear", "Defeat 200 enemies that would give you experience."),
    (11, QUEST, 0, 1, 25, "A Helping Hand", "Turn in a quest."),
    (12, QUEST, 0, 5, 50, "Odd Jobs", "Turn in 5 quests."),
    (2, QUEST, 0, 15, 75, "Someone Has to Do It", "Turn in 15 quests."),
    (14, DUNGEON_BOSS, 0, 1, 25, "Dungeon Crawl", "Defeat a dungeon boss."),
    (15, DUNGEON_BOSS, 0, 5, 50, "Going Down", "Defeat 5 dungeon bosses."),
    (4, DUNGEON_BOSS, 0, 10, 75, "Delving Deep", "Defeat 10 dungeon bosses."),
    (13, LEVEL, 0, 1, 50, "Growing Pains", "Gain a level on any character."),
    (3, LEVEL, 0, 3, 50, "Onward and Upward", "Gain 3 levels on any character."),
    (16, ACHIEVEMENT, 0, 1, 25, "Noteworthy", "Earn an achievement."),
    (5, ACHIEVEMENT, 0, 3, 50, "Worth Mentioning", "Earn 3 achievements."),
    (17, CRAFT, 0, 1, 25, "Handmade", "Craft an item with a profession."),
    (18, CRAFT, 0, 10, 50, "Busy Hands", "Craft 10 items with a profession."),
    (6, CRAFT, 0, 25, 50, "Made by Hand", "Craft 25 items with a profession."),
    (19, GATHER, 0, 10, 25, "A Walk in the Hills", "Gather from 10 herbs, mineral veins or skinnable creatures."),
    (7, GATHER, 0, 30, 50, "Out in the Field", "Gather from 30 herbs, mineral veins or skinnable creatures."),
    (30, GATHER, HERBALISM, 10, 25, "Green Thumb", "Pick 10 herbs."),
    (31, GATHER, MINING, 10, 25, "Pick and Shovel", "Mine 10 mineral veins."),
    (32, GATHER, SKINNING, 10, 25, "Leather Goods", "Skin 10 creatures."),
    (37, FISH, 0, 5, 25, "Gone Fishing", "Catch 5 fish."),
    (8, FISH, 0, 20, 50, "A Line in the Water", "Catch 20 fish."),
    (20, KILL_RARE, 0, 1, 50, "Rare Sighting", "Defeat a rare creature."),
    (21, KILL_ELITE, 0, 10, 25, "Tougher Than They Look", "Defeat 10 elite enemies that would give you experience."),
    (22, KILL_ELITE, 0, 40, 50, "Tougher Than You Look", "Defeat 40 elite enemies that would give you experience."),
    (23, KILL, BEAST, 25, 25, "Pelts and Fangs", "Defeat 25 beasts that would give you experience."),
    (24, KILL, UNDEAD, 25, 25, "Back to the Grave", "Defeat 25 undead that would give you experience."),
    (25, KILL, HUMANOID, 25, 25, "Bandit Season", "Defeat 25 humanoids that would give you experience."),
    (26, KILL, DEMON, 15, 25, "Unwelcome Guests", "Defeat 15 demons that would give you experience."),
    (27, KILL, ELEMENTAL, 15, 25, "Elemental Unrest", "Defeat 15 elementals that would give you experience."),
    (28, KILL, DRAGONKIN, 10, 25, "Scale and Claw", "Defeat 10 dragonkin that would give you experience."),
    (29, KILL, GIANT, 10, 25, "The Bigger They Are", "Defeat 10 giants that would give you experience."),
    (33, RAID_BOSS, 0, 1, 50, "Bring Friends", "Defeat a raid boss."),
    (34, BG_PLAY, 0, 1, 50, "Called to Battle", "Finish a battleground."),
    (35, BG_WIN, 0, 1, 50, "Victory Lap", "Win a battleground."),
    (36, PVP_KILL, 0, 5, 25, "Fair Fight", "Earn 5 honorable kills."),
]

STOCK_COLUMNS = ["kind", "item", "retail_id", "name"]


def norm(text):
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


def read_tsv(path):
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def build_stock(args):
    db2 = Path(args.db2)
    library = read_tsv(args.library)
    mounts = {r["retail_id"]: r for r in library if r["kind"] in ("mount", "flyer")}
    pets = {r["retail_id"]: r for r in library if r["kind"] == "pet"}

    excluded_items, excluded_names = set(), set()
    for path in args.exclude:
        for row in read_tsv(path):
            if row.get("item"):
                excluded_items.add(row["item"])
            for column in ("name", "comment"):
                if row.get(column):
                    excluded_names.add(norm(row[column]))

    rows = []

    def add(found, name):
        if not found or found["id"] in excluded_items or norm(name) in excluded_names:
            return
        if "[ph]" in name.lower():
            return
        rows.append({"kind": found["kind"], "item": found["id"], "retail_id": found["retail_id"], "name": found["name"]})

    with open(db2 / "Mount.csv", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            if "trading post" in row["SourceText_lang"].lower():
                add(mounts.get(row["ID"]), row["Name_lang"])

    with open(db2 / "BattlePetSpecies.csv", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            # A promotion's text can name the Trading Post in passing.
            if row["SourceText_lang"].lower().startswith("|cffffd200trading post"):
                found = pets.get(row["ID"])
                add(found, found["name"] if found else "")

    rows.sort(key=lambda r: (r["kind"], r["name"], int(r["item"])))
    with open(STOCK, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, STOCK_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(f"{STOCK.name}: {len(rows)} items")


def q(text):
    return "'" + text.replace("\\", "\\\\").replace("'", "''") + "'"


def price(kind):
    return {"mount": PRICE_GROUND, "flyer": PRICE_FLYER, "pet": PRICE_PET}[kind]


def deal(stock):
    """Hands the items out to the twelve months like cards, each kind in turn, so that every month
    gets some of each. The first ground mount a month is dealt is its bonus reward."""
    months = [{"bonus": None, "items": []} for _ in THEMES]
    for kind in ("mount", "flyer", "pet"):
        items = [r for r in stock if r["kind"] == kind]
        # Alphabetical order would give one month all of a family: every Darkmoon Charger, say.
        items.sort(key=lambda r: (int(r["item"]) * 2654435761) % 4294967296)
        for index, row in enumerate(items):
            month = months[index % len(months)]
            if kind == "mount" and month["bonus"] is None:
                month["bonus"] = row
            else:
                month["items"].append(row)
    return months


def write_sql():
    stock = read_tsv(STOCK)
    months = deal(stock)

    out = ["-- mod-trading-post: the monthly themes and capital proprietors. Written by tools/build_data.py.", ""]
    out += [
        "CREATE TABLE IF NOT EXISTS `mod_trading_post_theme` (",
        "  `theme` TINYINT UNSIGNED NOT NULL COMMENT 'calendar month, 1-12',",
        "  `name` VARCHAR(64) NOT NULL,",
        "  `description` VARCHAR(200) NOT NULL DEFAULT '',",
        "  `bonus_item` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'given for completing the log',",
        "  PRIMARY KEY (`theme`)",
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
        "",
        "CREATE TABLE IF NOT EXISTS `mod_trading_post_stock` (",
        "  `theme` TINYINT UNSIGNED NOT NULL,",
        "  `item` INT UNSIGNED NOT NULL,",
        "  `price` INT UNSIGNED NOT NULL,",
        "  `phase` TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'mod-individual-progression phase the account must reach',",
        "  `sort` SMALLINT UNSIGNED NOT NULL DEFAULT 0,",
        "  PRIMARY KEY (`theme`, `item`)",
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
        "",
        "CREATE TABLE IF NOT EXISTS `mod_trading_post_activity` (",
        "  `id` INT UNSIGNED NOT NULL,",
        "  `theme` TINYINT UNSIGNED NOT NULL COMMENT '0 = every month',",
        "  `type` TINYINT UNSIGNED NOT NULL,",
        "  `target` INT UNSIGNED NOT NULL DEFAULT 0,",
        "  `amount` INT UNSIGNED NOT NULL,",
        "  `points` INT UNSIGNED NOT NULL,",
        "  `sort` SMALLINT UNSIGNED NOT NULL DEFAULT 0,",
        "  `name` VARCHAR(64) NOT NULL,",
        "  `description` VARCHAR(160) NOT NULL,",
        "  PRIMARY KEY (`id`)",
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
        "",
        "DELETE FROM `mod_trading_post_theme`;",
        "DELETE FROM `mod_trading_post_stock`;",
        "DELETE FROM `mod_trading_post_activity`;",
        "",
    ]

    rows = []
    for number, ((name, description), month) in enumerate(zip(THEMES, months), 1):
        rows.append(f"({number}, {q(name)}, {q(description)}, {month['bonus']['item'] if month['bonus'] else 0})")
    out += ["INSERT INTO `mod_trading_post_theme` (`theme`, `name`, `description`, `bonus_item`) VALUES",
            ",\n".join(rows) + ";", ""]

    rows = []
    for number, month in enumerate(months, 1):
        for sort, row in enumerate(month["items"], 1):
            phase = FLYER_PHASE if row["kind"] == "flyer" else 0
            rows.append(f"({number}, {row['item']}, {price(row['kind'])}, {phase}, {sort})")
    out += ["-- " + "; ".join(f"{k}: {sum(1 for r in stock if r['kind'] == k)}" for k in ("mount", "flyer", "pet")),
            "INSERT INTO `mod_trading_post_stock` (`theme`, `item`, `price`, `phase`, `sort`) VALUES",
            ",\n".join(rows) + ";", ""]

    rows = []

    for sort, (activity_id, kind, target, amount, points, name, description) in enumerate(ACTIVITIES, 1):
        rows.append(f"({activity_id}, 0, {kind}, {target}, {amount}, {points}, {sort}, {q(name)}, {q(description)})")
    out += ["INSERT INTO `mod_trading_post_activity` (`id`, `theme`, `type`, `target`, `amount`, `points`, `sort`, `name`, `description`) VALUES",
            ",\n".join(rows) + ";", ""]

    out += [
        "-- DragonUI's Currency tab takes a row's icon and tooltip from an item the client knows.",
        f"UPDATE `item_template` SET `name` = {q(CURRENCY_NAME)}, `description` = {q(CURRENCY_TEXT)} WHERE `entry` = {CURRENCY_ITEM};",
        "-- Its translations would still call it a test token.",
        f"DELETE FROM `item_template_locale` WHERE `ID` = {CURRENCY_ITEM};",
        "",
        f"DELETE FROM `creature_template` WHERE `entry` IN ({NPC_ALLIANCE}, {NPC_HORDE});",
        "INSERT INTO `creature_template` (`entry`, `name`, `subname`, `gossip_menu_id`, `minlevel`, `maxlevel`, `faction`, `npcflag`, `speed_walk`, `speed_run`, `unit_class`, `unit_flags`, `unit_flags2`, `type`, `AIName`, `RegenHealth`, `flags_extra`, `ScriptName`) VALUES",
        f"({NPC_ALLIANCE}, 'Tessa Goodwin', 'Trading Post', {TEXT_NO_ADDON}, 60, 60, 35, 1, 1, 1.14286, 1, 768, 2048, 7, '', 1, 2, 'npc_trading_post'),",
        f"({NPC_HORDE}, 'Brakka Ironhand', 'Trading Post', {TEXT_NO_ADDON}, 60, 60, 35, 1, 1, 1.14286, 1, 768, 2048, 7, '', 1, 2, 'npc_trading_post');",
        f"DELETE FROM `creature_template_model` WHERE `CreatureID` IN ({NPC_ALLIANCE}, {NPC_HORDE});",
        "INSERT INTO `creature_template_model` (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`) VALUES",
        f"({NPC_ALLIANCE}, 0, 15594, 1, 1),",
        f"({NPC_HORDE}, 0, 8001, 1, 1);",
        f"DELETE FROM `creature` WHERE `guid` IN ({NPC_ALLIANCE}, {NPC_HORDE});",
        "INSERT INTO `creature` (`guid`, `id`, `map`, `spawnMask`, `phaseMask`, `position_x`, `position_y`, `position_z`, `orientation`, `spawntimesecs`, `curhealth`, `Comment`) VALUES",
        f"({NPC_ALLIANCE}, {NPC_ALLIANCE}, 0, 1, 1, -8800.73, 665.19, 96.2, 3.27, 300, 1, 'mod-trading-post: Stormwind, by the auction house'),",
        f"({NPC_HORDE}, {NPC_HORDE}, 1, 1, 1, 1674.7, -4440.0, 19.2, 5.35, 300, 1, 'mod-trading-post: Orgrimmar, by the auction house');",
        f"DELETE FROM `gossip_menu` WHERE `MenuID` = {TEXT_NO_ADDON};",
        f"INSERT INTO `gossip_menu` (`MenuID`, `TextID`) VALUES ({TEXT_NO_ADDON}, {TEXT_NO_ADDON});",
        f"DELETE FROM `npc_text` WHERE `ID` = {TEXT_NO_ADDON};",
        f"INSERT INTO `npc_text` (`ID`, `text0_0`, `BroadcastTextID0`) VALUES ({TEXT_NO_ADDON}, {q('The Trading Post needs the TradingPost addon. Install it, reload your interface and come back: I will show you everything on the shelves.')}, 0);",
        "",
    ]

    SQL.write_text("\n".join(out), encoding="utf-8")
    sizes = sorted(len(m["items"]) for m in months)
    print(f"{SQL.name}: {len(stock)} items, {sizes[0]}-{sizes[-1]} a month, {len(rows)} activities")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stock", action="store_true", help="make data/stock.tsv afresh first")
    parser.add_argument("--db2", help="folder with Mount.csv and BattlePetSpecies.csv")
    parser.add_argument("--library", help="the item library's table: id, kind, retail_id, name")
    parser.add_argument("--exclude", action="append", default=[], help="a shop's table with item, name or comment columns")
    args = parser.parse_args()
    if args.stock:
        if not args.db2 or not args.library:
            parser.error("--stock needs --db2 and --library")
        build_stock(args)
    write_sql()


if __name__ == "__main__":
    main()
