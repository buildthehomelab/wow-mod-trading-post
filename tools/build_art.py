#!/usr/bin/env python3
"""Builds addon/TradingPost/Art/*.tga and addon/TradingPost/ArtData.lua.

Cuts the pieces the windows use out of retail's Trading Post and Traveler's Log textures, using
retail's own atlas table, and packs them into two textures a 3.3.5a client can load: power-of-two,
RLE TGA, bottom-left origin. The output is committed, so this only runs when the set of pieces
changes. Needs Pillow; what it downloads from wago.tools stays in --cache.

wago.tools can lag behind its own atlas table: on 2026-11-02 its perks.blp had an older layout, so
half the pieces came out wrong. A file in <cache>/cdn/<file data id>, taken from Blizzard's CDN for
the same build, is used in preference; check the packed sheet whenever the art is rebuilt.

    build_art.py --cache <dir>
"""
import argparse
import csv
import io
import math
import struct
import urllib.request
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon" / "TradingPost"
ART = ADDON / "Art"

CASC = "https://wago.tools/api/casc/{}"
DB2 = "https://wago.tools/db2/{}/csv"
UA = {"User-Agent": "mod-trading-post/1.0"}

PERKS, ACTIVITIES, FREEZE, VERTICAL, CURRENCY_ICON = 4329247, 4499236, 4898396, 4331660, 4696085
SIZE = 1024
GAP = 2

# Retail's atlas names. A number is the scale to pack at, for what is drawn smaller than retail's art.
LOG = {
    "activities-background": 1,
    "activities-incomplete": 1,
    "activities-complete": 1,
    "activities-container": 0.75,
    "activities-divider": 1,
    "activities-divider-vertical": 1,
    "activities-bar-background": 1,
    "activities-bar-border": 1,
    "activities-bar-fill": 1,
    "activities-bar-fill-bonus": 1,
    "activities-chest-sw": 1,
    "activities-chest-sw-glow": 1,
    "activities-chest-org": 1,
    "activities-chest-org-glow": 1,
    "activities-complete-diamond": 1,
    "activities-incomplete-diamond": 1,
    "activities-ribbon": 1,
    "activities-icon-checkmark": 1,
    "activities-icon-lock": 1,
}
POST = {
    "perks-list-active": 1,
    "perks-list-hover": 1,
    "perks-list-borderlines": 1,
    "perks-list-edgeflare": 1,
    "perks-list-nineslice-center": 1,
    "perks-list-nineslice-cornertopleft": 1,
    "_perks-list-nineslice-edgetop": 1,
    "!perks-list-nineslice-edgeleft": 1,
    "perks-hold-nineslice-center": 1,
    "perks-hold-nineslice-cornertopleft": 1,
    "perks-hold-nineslice-cornertopright": 1,
    "perks-hold-nineslice-cornerbottomleft": 1,
    "perks-hold-nineslice-cornerbottomright": 1,
    "_perks-hold-nineslice-edgetop": 1,
    "!perks-hold-nineslice-edgeleft": 1,
    "perks-divider": 1,
    "perks-divider-short": 1,
    "perks-border-square-gold": 1,
    "perks-border-square-gray": 1,
    "perks-buybutton-greenglow": 1,
    "perks-mount-shadow": 0.6,
    "perks-clock": 1,
    "perks-owned-small": 1,
    "perks-frost-bg": 1,
    "perks-frost-frame-1": 1,
    "perks-slot-empty": 1,
}


def cached(url, path):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
            path.write_bytes(r.read())
    return path.read_bytes()


def texture(cache, fdid):
    """A retail texture's top level. These are raw BGRA BLPs, which Pillow doesn't read."""
    pinned = cache / "cdn" / str(fdid)
    data = pinned.read_bytes() if pinned.exists() else cached(CASC.format(fdid), cache / "casc" / str(fdid))
    width, height = struct.unpack("<II", data[12:20])
    start = struct.unpack("<I", data[20:24])[0]
    if data[8] == 3:
        return Image.frombuffer("RGBA", (width, height), data[start:start + width * height * 4], "raw", "BGRA", 0, 1).copy()
    return Image.open(io.BytesIO(data)).convert("RGBA")


def atlas_members(cache):
    atlases = {}
    text = cached(DB2.format("UiTextureAtlas"), cache / "db2" / "UiTextureAtlas.csv").decode("utf-8")
    for row in csv.DictReader(io.StringIO(text)):
        atlases[row["ID"]] = int(row["FileDataID"])
    members = {}
    text = cached(DB2.format("UiTextureAtlasMember"), cache / "db2" / "UiTextureAtlasMember.csv").decode("utf-8")
    for row in csv.DictReader(io.StringIO(text)):
        fdid = atlases.get(row["UiTextureAtlasID"])
        if fdid in (PERKS, ACTIVITIES, FREEZE, VERTICAL):
            box = tuple(int(row["Committed" + side]) for side in ("Left", "Top", "Right", "Bottom"))
            members[row["CommittedName"]] = (fdid, box)
    return members


def stage_light():
    """A soft pool of light for the stage; not retail art, where a 3D scene does this."""
    size = 128
    light = Image.new("RGBA", (size, size))
    middle = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            distance = min(1, math.hypot(x - middle, y - middle) / middle)
            light.putpixel((x, y), (255, 255, 255, round(255 * (1 - distance) ** 2)))
    return light


def extrude(sheet, piece, x, y):
    """Copies a piece's edge pixels into the gap around it, so filtering can't pick up a neighbour."""
    width, height = piece.size
    sheet.paste(piece.crop((0, 0, width, 1)).resize((width, GAP)), (x, y - GAP))
    sheet.paste(piece.crop((0, height - 1, width, height)).resize((width, GAP)), (x, y + height))
    sheet.paste(piece.crop((0, 0, 1, height)).resize((GAP, height)), (x - GAP, y))
    sheet.paste(piece.crop((width - 1, 0, width, height)).resize((GAP, height)), (x + width, y))
    for corner_x, corner_y, at_x, at_y in ((0, 0, x - GAP, y - GAP), (width - 1, 0, x + width, y - GAP),
                                           (0, height - 1, x - GAP, y + height), (width - 1, height - 1, x + width, y + height)):
        sheet.paste(Image.new("RGBA", (GAP, GAP), piece.getpixel((corner_x, corner_y))), (at_x, at_y))


def pack(pieces):
    """Tallest first, in rows. Returns the sheet and {name: (x, y, width, height)}."""
    sheet = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    places = {}
    x, y, row = GAP, GAP, 0
    for name, piece in sorted(pieces.items(), key=lambda item: (-item[1].height, item[0])):
        if piece.width + GAP * 2 > SIZE:
            raise SystemExit("%s doesn't fit" % name)
        if x + piece.width + GAP > SIZE:
            x, y, row = GAP, y + row + GAP * 2, 0
        if y + piece.height + GAP > SIZE:
            raise SystemExit("%s doesn't fit" % name)
        sheet.paste(piece, (x, y))
        extrude(sheet, piece, x, y)
        places[name] = (x, y, piece.width, piece.height)
        x += piece.width + GAP * 2
        row = max(row, piece.height)
    return sheet, places


def lua_name(name):
    return name.lstrip("_!").replace("activities-", "").replace("perks-", "").replace("-", "_")


def build(cache):
    members = atlas_members(cache)
    sources = {}
    written = ["-- Written by tools/build_art.py: where each piece sits in Art/*.tga, and retail's size for it.",
               "", "local T = TradingPost", "", "T.ArtData = {"]
    ART.mkdir(exist_ok=True)
    for file, wanted in (("log", LOG), ("post", POST)):
        pieces = {}
        drawn = {}
        for name, scale in wanted.items():
            fdid, box = members[name]
            if fdid not in sources:
                sources[fdid] = texture(cache, fdid)
            piece = sources[fdid].crop(box)
            drawn[name] = piece.size
            if scale != 1:
                piece = piece.resize((max(1, round(piece.width * scale)), max(1, round(piece.height * scale))), Image.LANCZOS)
            pieces[name] = piece
        if file == "post":
            icon = texture(cache, CURRENCY_ICON)
            pieces["currency"] = icon
            drawn["currency"] = icon.size
            pieces["stage_light"] = stage_light()
            drawn["stage_light"] = pieces["stage_light"].size
        sheet, places = pack(pieces)
        sheet.save(ART / (file + ".tga"), compression="tga_rle", orientation=-1)
        written.append('\t%s = {' % file)
        for name in sorted(places):
            x, y, width, height = places[name]
            written.append("\t\t%s = { %d, %d, %d, %d, %d, %d }," % (lua_name(name), x, y, width, height, *drawn[name]))
        written.append("\t},")
        print("%s.tga: %d pieces, %d bytes" % (file, len(places), (ART / (file + ".tga")).stat().st_size))
    written.append("}")
    (ADDON / "ArtData.lua").write_text("\n".join(written) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=Path, required=True)
    build(parser.parse_args().cache.expanduser())
