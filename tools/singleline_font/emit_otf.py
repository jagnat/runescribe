#!/usr/bin/env python3
"""font.json -> installable single-line OTF (open CFF contours).

Open contours render as hairlines or invisibly in ordinary apps (fills have
zero area) but are the standard convention for engraving/plotter single-line
fonts. For real plotting use the plot library's text() -> SVG path.
"""

import json
import os
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen

UPM = 1000
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "RunescribeSingleLine.otf")
FAMILY = "Runescribe SingleLine"


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "font.json")
    with open(src) as f:
        font = json.load(f)
    glyphs = font["glyphs"]
    adv = int(round(font["advance"] * UPM))

    def to_font(p):
        return (round(p[0] * UPM, 1), round(-p[1] * UPM, 1))  # y-up

    order = [".notdef", "space"] + [f"uni{c:04X}" for c in range(33, 127)]
    cmap = {32: "space"}
    charstrings = {}
    advances = {}

    pen = T2CharStringPen(adv, None)
    pen.moveTo((50, 0))
    pen.lineTo((50, 700))
    pen.lineTo((550, 700))
    pen.lineTo((550, 0))
    pen.closePath()
    charstrings[".notdef"] = pen.getCharString()
    advances[".notdef"] = (adv, 50)

    pen = T2CharStringPen(adv, None)
    charstrings["space"] = pen.getCharString()
    advances["space"] = (adv, 0)

    for code in range(33, 127):
        name = f"uni{code:04X}"
        cmap[code] = name
        g = glyphs.get(chr(code), {"strokes": []})
        pen = T2CharStringPen(adv, None)
        for st in g["strokes"]:
            if "dot" in st:
                # tiny out-and-back so the dot survives font rendering
                x, y = to_font(st["dot"])
                pen.moveTo((x - 4, y))
                pen.lineTo((x + 4, y))
                pen.closePath()
                continue
            cubics = st["cubics"]
            pen.moveTo(to_font(cubics[0][0]))
            for b in cubics:
                pen.curveTo(to_font(b[1]), to_font(b[2]), to_font(b[3]))
            if st.get("closed"):
                pass  # curve chain already returns to start
            pen.closePath()
        charstrings[name] = pen.getCharString()
        advances[name] = (adv, 0)

    fb = FontBuilder(UPM, isTTF=False)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupCFF(FAMILY.replace(" ", ""), {"FullName": FAMILY, "FamilyName": FAMILY,
                                          "Notice": "Single-line derivative of Maple Mono (OFL 1.1)"},
                charstrings, {})
    fb.setupHorizontalMetrics(advances)
    fb.setupHorizontalHeader(ascent=1020, descent=-300)
    fb.setupNameTable({"familyName": FAMILY, "styleName": "Regular",
                       "uniqueFontIdentifier": FAMILY + " 1.0",
                       "fullName": FAMILY,
                       "psName": FAMILY.replace(" ", "") + "-Regular",
                       "version": "Version 1.0",
                       "licenseDescription": "SIL Open Font License 1.1. Derived from Maple Mono (c) 2022 The Maple Mono Project Authors.",
                       "licenseInfoURL": "https://openfontlicense.org"})
    fb.setupOS2(sTypoAscender=1020, sTypoDescender=-300, usWinAscent=1020, usWinDescent=300,
                sCapHeight=730, sxHeight=550, achVendID="RUNE")
    fb.setupPost(isFixedPitch=1)
    fb.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
