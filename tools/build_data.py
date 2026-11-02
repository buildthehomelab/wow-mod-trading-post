#!/usr/bin/env python3
"""Builds data/sql/db-world/mod_trading_post_world.sql.

The twelve monthly themes, each with its stock, its Traveler's Log activities and its bonus reward.
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

BEAST, DRAGONKIN, DEMON, ELEMENTAL, GIANT, UNDEAD, HUMANOID, MECHANICAL = 1, 2, 3, 4, 5, 6, 7, 9
HERBALISM, MINING, SKINNING = 182, 186, 393

# Every month: type, target, amount, points, name, description.
EVERY_MONTH = [
    (KILL, 0, 200, 75, "Keeping the Roads Clear", "Defeat 200 enemies that would give you experience."),
    (QUEST, 0, 25, 100, "Odd Jobs", "Turn in 25 quests."),
    (LEVEL, 0, 3, 75, "Onward and Upward", "Gain 3 levels on any character."),
    (DUNGEON_BOSS, 0, 10, 100, "Delving Deep", "Defeat 10 dungeon bosses."),
    (ACHIEVEMENT, 0, 3, 50, "Worth Mentioning", "Earn 3 achievements."),
    (CRAFT, 0, 25, 75, "Made by Hand", "Craft 25 items with a profession."),
    (GATHER, 0, 40, 75, "Out in the Field", "Gather from 40 herbs, mineral veins or skinnable creatures."),
    (FISH, 0, 25, 50, "A Line in the Water", "Catch 25 fish."),
]

# Rotating: this many join the list above each month, in turn. Together a month offers well over
# the 1,000 points the log asks for, so nobody has to do all of it.
ROTATING = [
    (KILL, BEAST, 80, 50, "Pelts and Fangs", "Defeat 80 beasts that would give you experience."),
    (KILL, UNDEAD, 60, 50, "Back to the Grave", "Defeat 60 undead that would give you experience."),
    (KILL, HUMANOID, 80, 50, "Bandit Season", "Defeat 80 humanoids that would give you experience."),
    (KILL, DEMON, 30, 50, "Unwelcome Guests", "Defeat 30 demons that would give you experience."),
    (KILL, ELEMENTAL, 40, 50, "Elemental Unrest", "Defeat 40 elementals that would give you experience."),
    (KILL, DRAGONKIN, 20, 50, "Scale and Claw", "Defeat 20 dragonkin that would give you experience."),
    (KILL, GIANT, 15, 50, "The Bigger They Are", "Defeat 15 giants that would give you experience."),
    (KILL, MECHANICAL, 25, 50, "Spare Parts", "Defeat 25 mechanical enemies that would give you experience."),
    (KILL_ELITE, 0, 40, 75, "Tougher Than They Look", "Defeat 40 elite enemies that would give you experience."),
    (KILL_RARE, 0, 3, 100, "Rare Sightings", "Defeat 3 rare creatures."),
    (RAID_BOSS, 0, 5, 150, "Bring Friends", "Defeat 5 raid bosses."),
    (GATHER, HERBALISM, 30, 50, "Green Thumb", "Pick 30 herbs."),
    (GATHER, MINING, 30, 50, "Pick and Shovel", "Mine 30 mineral veins."),
    (GATHER, SKINNING, 30, 50, "Leather Goods", "Skin 30 creatures."),
    (BG_PLAY, 0, 5, 75, "Called to Battle", "Finish 5 battlegrounds."),
    (BG_WIN, 0, 3, 100, "Victory Laps", "Win 3 battlegrounds."),
    (PVP_KILL, 0, 25, 75, "Fair Fight", "Earn 25 honorable kills."),
]
ROTATING_PER_MONTH = 10

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

    # Ids are the theme and place, so that a change to one month's list leaves the others' progress
    # alone: progress is stored by id. Every month's come first, under 100.
    def activity(activity_id, theme, entry, sort):
        kind, target, amount, points, name, description = entry
        rows.append(f"({activity_id}, {theme}, {kind}, {target}, {amount}, {points}, {sort}, {q(name)}, {q(description)})")

    for sort, entry in enumerate(EVERY_MONTH, 1):
        activity(sort, 0, entry, sort)
    for number in range(1, len(THEMES) + 1):
        for offset in range(ROTATING_PER_MONTH):
            entry = ROTATING[((number - 1) * ROTATING_PER_MONTH + offset) % len(ROTATING)]
            activity(number * 100 + offset + 1, number, entry, len(EVERY_MONTH) + offset + 1)
    out += ["INSERT INTO `mod_trading_post_activity` (`id`, `theme`, `type`, `target`, `amount`, `points`, `sort`, `name`, `description`) VALUES",
            ",\n".join(rows) + ";", ""]

    out += [
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
        f"({NPC_ALLIANCE}, {NPC_ALLIANCE}, 0, 1, 1, -8806.2, 664.6, 96.2, 1.56, 300, 1, 'mod-trading-post: Stormwind, by the auction house'),",
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
