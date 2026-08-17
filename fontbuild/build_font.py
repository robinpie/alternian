#!/usr/bin/env python3
import argparse, os, re, shutil, subprocess, sys
import numpy as np
from PIL import Image

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.svgLib.path import SVGPath
from fontTools.misc.transform import Transform
import pathops

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, os.pardir, "AlternianAlphabetComplete.webp")

# ---------------------------------------------------------------- chart layout
H_LINES = [(179, 256), (399, 476), (615, 692), (831, 908)]  # (mid, bottom) per table
V_BORDERS = [34, 111, 188, 265, 342, 419, 496, 573, 650, 727, 804, 881, 958]
ROWS = [
    list("ABCDEFGHIJKL"),
    list("MNOPQRSTUVWX"),
    ["Y", "Z", "'", "(", ")", "-", ".", ",", "?", "!", "+"],
    list("1234567890"),
]
PAD = 4  # px inset to clear the table rules

GNAME = {
    "'": "quotesingle", "(": "parenleft", ")": "parenright", "-": "hyphen",
    ".": "period", ",": "comma", "?": "question", "!": "exclam", "+": "plus",
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
    "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
}
glyph_name = lambda ch: GNAME.get(ch, ch)

# ---------------------------------------------------------------- font metrics
UPM = 1000
SCALE = 15.0          # font units per source pixel
BASELINE_FROM_BOT = 10  # px above the cell interior bottom
SIDEBEARING = 60      # font units
SPACE_WIDTH = 340


def cells(img):
    """Yield (char, cell_bitmap, ink_bbox_in_cell) for all 45 chart cells."""
    ink = np.array(img.convert("L")) < 128
    for ti, (mid, bot) in enumerate(H_LINES):
        y0, y1 = mid + PAD, bot - PAD
        for j, ch in enumerate(ROWS[ti]):
            x0, x1 = V_BORDERS[j] + PAD, V_BORDERS[j + 1] - PAD
            cell = ink[y0:y1, x0:x1]
            ys, xs = np.nonzero(cell)
            if len(ys) == 0:
                raise RuntimeError(f"empty cell for {ch!r}")
            yield ch, cell, (xs.min(), ys.min(), xs.max(), ys.max())


def write_pbm(bitmap, path):
    h, w = bitmap.shape
    with open(path, "wb") as f:
        f.write(b"P4\n%d %d\n" % (w, h))
        f.write(np.packbits(bitmap.astype(np.uint8), axis=1).tobytes())


def supersample(cell, factor):
    if factor <= 1:
        return cell
    im = Image.fromarray((cell * 255).astype("uint8"), "L")
    im = im.resize((im.width * factor, im.height * factor), Image.BICUBIC)
    return np.array(im) >= 128


def trace(cell, tmpdir, tag, factor, alphamax, opttolerance):
    """Run potrace, return a RecordingPen of the outline in cell-pixel coords (y down)."""
    big = supersample(cell, factor)
    pbm = os.path.join(tmpdir, f"{tag}.pbm")
    svg = os.path.join(tmpdir, f"{tag}.svg")
    write_pbm(big, pbm)
    subprocess.run(
        ["potrace", "-b", "svg", "-u", "100", "-a", str(alphamax),
         "-O", str(opttolerance), "-t", "1", pbm, "-o", svg],
        check=True, capture_output=True,
    )
    text = open(svg).read()
    m = re.search(r'transform="translate\(([-\d.]+),([-\d.]+)\)\s*scale\(([-\d.]+),([-\d.]+)\)"', text)
    if not m:
        raise RuntimeError(f"no potrace transform for {tag}")
    tx, ty, sx, sy = (float(v) for v in m.groups())

    rec = RecordingPen()
    # potrace's group transform -> image px (y down), then /factor -> cell px
    t = Transform(1.0 / factor, 0, 0, 1.0 / factor, 0, 0).transform(
        Transform(sx, 0, 0, sy, tx, ty))
    SVGPath.fromstring(text.encode()).draw(TransformPen(rec, t))
    return rec


def cleanup(rec):
    """Boolean-union the contours: fixes winding, drops overlaps and self-intersections."""
    sp = pathops.Path()
    rec.replay(sp.getPen())
    sp.simplify(fix_winding=True, keep_starting_points=False)
    out = RecordingPen()
    sp.draw(out)
    return out


def build(factor, alphamax, opttolerance, out_otf, out_ttf, tmpdir):
    img = Image.open(SRC)
    os.makedirs(tmpdir, exist_ok=True)

    charstrings, metrics, order = {}, {}, [".notdef", "space"]
    ch_for_glyph, bounds = {}, {}

    for ch, cell, (ix0, iy0, ix1, iy1) in cells(img):
        gname = glyph_name(ch)
        rec = cleanup(trace(cell, tmpdir, gname, factor, alphamax, opttolerance))

        h = cell.shape[0]
        y_base = h - BASELINE_FROM_BOT           # baseline in cell px (y down)
        # cell px (y down) -> font units (y up), ink left edge -> SIDEBEARING
        t = Transform(SCALE, 0, 0, -SCALE,
                      SIDEBEARING - ix0 * SCALE, y_base * SCALE)

        width = int(round((ix1 - ix0 + 1) * SCALE + 2 * SIDEBEARING))
        pen = T2CharStringPen(width, None)
        rec.replay(TransformPen(pen, t))
        charstrings[gname] = pen.getCharString()
        metrics[gname] = (width, SIDEBEARING)
        order.append(gname)
        ch_for_glyph[gname] = ch

        bp = BoundsPen(None)
        rec.replay(TransformPen(bp, t))
        bounds[gname] = bp.bounds

    # space: blank
    p = T2CharStringPen(SPACE_WIDTH, None)
    charstrings["space"] = p.getCharString()
    metrics["space"] = (SPACE_WIDTH, 0)

    # .notdef: hollow box, so missing glyphs are visible rather than silent
    p = T2CharStringPen(SPACE_WIDTH, None)
    for (x0, y0, x1, y1), rev in (((60, 0, 280, 700), False), ((110, 50, 230, 650), True)):
        pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        if rev:
            pts.reverse()
        p.moveTo(pts[0])
        for pt in pts[1:]:
            p.lineTo(pt)
        p.closePath()
    charstrings[".notdef"] = p.getCharString()
    metrics[".notdef"] = (SPACE_WIDTH, 60)

    cmap = {0x20: "space"}
    for gname, ch in ch_for_glyph.items():
        cmap[ord(ch)] = gname
        if ch.isalpha():                 # Alternian is caseless: a-z -> A-Z glyphs
            cmap[ord(ch.lower())] = gname
    cmap[0x2019] = "quotesingle"         # curly apostrophe -> same mark
    cmap[0x00A0] = "space"               # no-break space

    # Parallel Private Use Area block, U+E000..U+E02C:
    #   E000..E019  A..Z      E01A..E023  0..9      E024..E02C  ' ( ) - . , ? ! +
    # Same 45 glyphs as the Latin mapping, but encoded as distinct characters
    # rather than as a Latin cipher. Basis for a future UCSUR submission.
    for i, ch in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):
        cmap[0xE000 + i] = glyph_name(ch)
    for i, ch in enumerate("0123456789"):
        cmap[0xE01A + i] = glyph_name(ch)
    for i, ch in enumerate(["'", "(", ")", "-", ".", ",", "?", "!", "+"]):
        cmap[0xE024 + i] = glyph_name(ch)

    fb = FontBuilder(UPM, isTTF=False)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupHorizontalMetrics(metrics)

    ys = [v for b in bounds.values() if b for v in (b[1], b[3])]
    asc, desc = int(round(max(ys))), int(round(min(ys)))

    fb.setupHorizontalHeader(ascent=asc, descent=desc, lineGap=0)
    fb.setupNameTable({
        "familyName": "Alternian",
        "styleName": "Regular",
        "uniqueFontIdentifier": "Alternian-Regular-1.000",
        "fullName": "Alternian Regular",
        "psName": "Alternian-Regular",
        "version": "Version 1.000",
        "copyright": "Alternian alphabet by BlackholeWI, Aepokk, YUURG and Joseph Staleknight. "
                     "Homestuck is by Andrew Hussie.",
        "description": "Traced from the Alternian alphabet chart.",
    })
    fb.setupCFF("Alternian-Regular",
                {"FullName": "Alternian Regular", "FamilyName": "Alternian",
                 "version": "1.000"}, charstrings, {})
    fb.setupOS2(sTypoAscender=asc, sTypoDescender=desc, sTypoLineGap=0,
                usWinAscent=asc, usWinDescent=abs(desc),
                sCapHeight=int(0.70 * UPM), sxHeight=int(0.70 * UPM),
                achVendID="ALTN", fsType=0)
    fb.setupPost(isFixedPitch=0)
    fb.save(out_otf)
    print(f"wrote {out_otf}  ({len(order)} glyphs, ascent {asc}, descent {desc})")

    # TrueType flavour: cubic -> quadratic
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.pens.cu2quPen import Cu2QuPen
    tb = FontBuilder(UPM, isTTF=True)
    tb.setupGlyphOrder(order)
    tb.setupCharacterMap(cmap)
    glyphs = {}
    for name, cs in charstrings.items():
        tp = TTGlyphPen(None)
        cs.draw(Cu2QuPen(tp, 0.6))
        glyphs[name] = tp.glyph()
    tb.setupGlyf(glyphs)
    tb.setupHorizontalMetrics(metrics)
    tb.setupHorizontalHeader(ascent=asc, descent=desc, lineGap=0)
    tb.setupNameTable({
        "familyName": "Alternian", "styleName": "Regular",
        "uniqueFontIdentifier": "Alternian-Regular-1.000",
        "fullName": "Alternian Regular", "psName": "Alternian-Regular",
        "version": "Version 1.000",
        "copyright": "Alternian alphabet by BlackholeWI, Aepokk, YUURG and Joseph Staleknight. "
                     "Homestuck is by Andrew Hussie.",
    })
    tb.setupOS2(sTypoAscender=asc, sTypoDescender=desc, sTypoLineGap=0,
                usWinAscent=asc, usWinDescent=abs(desc),
                sCapHeight=int(0.70 * UPM), sxHeight=int(0.70 * UPM),
                achVendID="ALTN", fsType=0)
    tb.setupPost(isFixedPitch=0)
    tb.save(out_ttf)
    print(f"wrote {out_ttf}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    # NOTE: factor MUST default to 1. The chart is pure 1-bit with no anti-aliasing,
    # so bicubic-upscaling + re-thresholding just rebuilds the pixel staircase at N x
    # the size, and potrace then traces those steps as genuine features. potrace's own
    # curve fitting on the raw bitmap is much smoother. Verified at x1/x4/x8.
    ap.add_argument("--factor", type=int, default=1)
    ap.add_argument("--alphamax", type=float, default=1.0)
    ap.add_argument("--opttolerance", type=float, default=0.2)
    ap.add_argument("--otf", default=os.path.join(HERE, os.pardir, "Alternian-Regular.otf"))
    ap.add_argument("--ttf", default=os.path.join(HERE, os.pardir, "Alternian-Regular.ttf"))
    ap.add_argument("--tmp", default=os.path.join(HERE, "trace"))
    a = ap.parse_args()
    build(a.factor, a.alphamax, a.opttolerance, a.otf, a.ttf, a.tmp)
