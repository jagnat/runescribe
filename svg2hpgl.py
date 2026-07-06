"""svg2hpgl.py - Convert an SVG into HP-GL records for an HP 7440A ColorPro pen plotter.

The companion to svg2gcode.py. Instead of emitting G-code for the 3D-printer
plotter, this emits HP-GL (Hewlett-Packard Graphics Language), the language the
HP 7440A speaks over RS-232.

The output is written as a *record file*: one HP-GL instruction per line, each
line guaranteed to be <= MAX_RECORD bytes. This matters because the base 7440A
(no Graphics Enhancement Cartridge) has a tiny input buffer and no robust flow
control. The companion streamer, hpgl_stream.py, sends these records one at a
time using the plotter's Enquire/Acknowledge handshake so the buffer is never
overrun.

Pipeline (mirrors svg2gcode.py):
    (optional) vpype linemerge/linesort    cuts pen-up travel  (optimize_with_vpype)
    SVG line/circle/ellipse elements --> SVG <path>            (convert_to_path)
    parse_groups --> per-style line-segment curves            (this file)
    resolve_pens --> assign each style a carousel pen, merge   (this file)
    curves --> polylines in plotter units                     (this file)
    polylines --> chunked PU/PD records, per pen               (this file)

Styles and pens: ink is grouped by (stroke colour, stroke width) -- each such
"style" is drawn in one pass with one carousel pen, then an SP pen-change, then
the next. The sketch no longer picks a pen; the (style -> pen) assignment is made
here at convert time, from --pens/--map flags, an interactive prompt, or a saved
<input>.pens.json sidecar (see resolve_pens).

HP-GL primer (what we actually emit):
    IN;            initialize the plotter
    SP1;           select pen 1 (SP2, SP3, ... for a pen change per colour)
    PU x,y;        pen up, move to (x,y)        -- travel, no line
    PD x,y,...;    pen down, draw through points -- a PD takes a coord list
    PU;            pen up (park); also emitted before each SP pen-change
    SP0;           return pen to the carousel
Coordinates are integer *plotter units*: 40 units/mm (1016 units/inch). The
plotter origin is bottom-left and Y grows upward, so we flip Y from SVG space.
"""

import os
import re
import sys
import json
import math
import shutil
import datetime
import tempfile
import subprocess
from copy import deepcopy
from xml.etree import ElementTree

from svg_to_gcode.svg_parser import Path, Transformation
from svg_to_gcode.geometry import LineSegmentChain, Line

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Input SVG. Override on the command line: python3 svg2hpgl.py path/to/file.svg
path = 'output_260608_174939.svg'

# The 7440A carousel holds up to 8 pens.
MAX_PEN = 8

# Ink is grouped by (stroke colour, stroke width): each distinct combination is
# a "style" that gets assigned one carousel pen. The assignment is chosen at
# convert time (interactively, from --pens/--map flags, or a saved sidecar) --
# the sketch no longer bakes in a pen. See resolve_pens.

# Common SVG colour-name spellings normalised to hex, so a style key is stable
# whether the SVG names a colour or gives its hex -- and survives a vpype pass,
# which rewrites names to hex.
COLOR_NAMES = {
    'black': '#000000', 'white': '#ffffff', 'red': '#ff0000',
    'green': '#008000', 'blue': '#0000ff', 'orange': '#ff8c00',
    'purple': '#800080', 'brown': '#8b4513', 'magenta': '#ff00ff',
}

# Plotter-unit drawing area to fit the artwork into. These are the HP 7440A
# US/Letter hard-clip limits (~10.1in x 7.5in landscape); 40 plotter units == 1mm.
# Verified on hardware: a box at (40,40)-(10260,7610) draws cleanly within reach.
plot_x_min = 0.0
plot_x_max = 10300.0
plot_y_min = 0.0
plot_y_max = 7650.0

# Extra margin (plotter units) kept clear inside the area above. Keeps the pen
# off the hard stops (40 units == 1mm).
margin = 40.0

# Rotate the artwork counter-clockwise by this many degrees before fitting.
# Use 90 to align a portrait drawing with landscape paper for a larger plot.
# The fit/center/flip step runs after rotation, so any pivot works.
rotate = 0

# Fit to the SVG canvas (viewBox / width x height) instead of the tight bounding
# box of the ink. When True the drawing keeps its position and margins within the
# canvas rather than being scaled up to fill the paper. Override with --canvas on
# the command line. Incompatible with rotate != 0 (the canvas box doesn't rotate
# with the geometry), so canvas-fit is ignored when rotating.
fit_to_canvas = False

# Maximum bytes per emitted record (including the trailing ';'). The base 7440A
# accepts only small buffers, so keep this comfortably under 60. The streamer's
# Enquire/Acknowledge block size must be >= this value.
MAX_RECORD = 58

# Treat two points closer than this (plotter units) as coincident when deciding
# whether consecutive curves form one continuous polyline.
JOIN_EPSILON = 1e-3

# ---------------------------------------------------------------------------
# SVG element normalization (lifted from svg2gcode.py)
# ---------------------------------------------------------------------------

def convert_to_path(node, ns, style, d):
    node.clear()
    # parse_root only recognizes the namespaced {svg}path tag.
    node.tag = ns + 'path'
    if style is not None:
        node.set('style', style)
    node.set('d', d)


def _points_to_path(points, close):
    """Turn an SVG points="x,y x,y ..." list into a path 'd' string.

    Coordinates may be separated by commas and/or whitespace; we just pull out
    every number in order and pair them up. `close` adds a trailing 'Z' (polygon).
    """
    nums = [float(n) for n in re.findall(r'[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?', points)]
    pts = list(zip(nums[0::2], nums[1::2]))
    if len(pts) < 2:
        return None
    d = 'M {} {}'.format(*pts[0])
    d += ''.join(' L {} {}'.format(x, y) for (x, y) in pts[1:])
    if close:
        d += ' Z'
    return d


def normalize_primitives(root, ns):
    """Rewrite primitive shapes as <path> so parse_root flattens them.

    Group <transform> attributes (translate/rotate/...) live on ancestor <g>
    elements, not on these shape nodes, so clearing/retagging a shape leaves the
    inherited transforms intact -- parse_root still applies them to the path.
    """
    for node in root.iter():
        if node.tag in (ns + 'polygon', ns + 'polyline'):
            points = node.get('points')
            if not points:
                continue
            d = _points_to_path(points, close=node.tag == ns + 'polygon')
            if d is None:
                continue
            convert_to_path(node, ns, node.get('style'), d)
        elif node.tag == ns + 'line':
            x1 = float(node.get('x1')); x2 = float(node.get('x2'))
            y1 = float(node.get('y1')); y2 = float(node.get('y2'))
            style = node.get('style')
            d = 'M {} {} L {} {}'.format(x1, y1, x2, y2)
            convert_to_path(node, ns, style, d)
        elif node.tag == ns + 'rect':
            x = float(node.get('x', 0)); y = float(node.get('y', 0))
            w = float(node.get('width', 0)); h = float(node.get('height', 0))
            if w <= 0 or h <= 0:
                continue
            style = node.get('style')
            # Sharp-cornered rectangle as a closed path. (rx/ry rounding is
            # ignored -- these SVGs use plain rects.)
            d = 'M {0} {1} L {2} {1} L {2} {3} L {0} {3} Z'.format(x, y, x + w, y + h)
            convert_to_path(node, ns, style, d)
        elif node.tag == ns + 'circle':
            r = float(node.get('r'))
            cx = float(node.get('cx')); cy = float(node.get('cy'))
            style = node.get('style')
            d = 'M {1} {0} A {3} {3} 0 0 0 {2} {0} A {3} {3} 0 0 0 {1} {0}' \
                .format(cy, cx - r, cx + r, r)
            convert_to_path(node, ns, style, d)
        elif node.tag == ns + 'ellipse':
            cx = float(node.get('cx')); cy = float(node.get('cy'))
            rx = float(node.get('rx')); ry = float(node.get('ry'))
            style = node.get('style')
            d = 'M {1} {0} A {3} {4} 0 0 0 {2} {0} A {3} {4} 0 0 0 {1} {0}' \
                .format(cy, cx - rx, cx + rx, rx, ry)
            convert_to_path(node, ns, style, d)


# ---------------------------------------------------------------------------
# Colour grouping (parse the SVG into per-pen curve buckets)
# ---------------------------------------------------------------------------

def _style_value(element, key):
    """Return the value of a presentation property, from the attribute or the
    `style` string, or None if the element doesn't set it."""
    val = element.get(key)
    if val is None:
        style = element.get('style')
        if style:
            m = re.search(re.escape(key) + r'\s*:\s*([^;]+)', style)
            if m:
                val = m.group(1)
    return val.strip() if val is not None else None


def _element_stroke(element):
    """Stroke colour declared on this element, or None if unset. 'none' means
    the element paints no stroke, so it's treated as unset for grouping."""
    stroke = _style_value(element, 'stroke')
    if stroke is None or stroke.lower() == 'none':
        return None
    return stroke


def _element_stroke_width(element):
    """Stroke width declared on this element (attribute or style), or None."""
    val = _style_value(element, 'stroke-width')
    if val is None:
        return None
    m = re.match(r'[-+]?[0-9]*\.?[0-9]+', val)
    return float(m.group(0)) if m else None


def _norm_color(stroke):
    """Normalise a stroke colour to lowercase hex so a style key is stable across
    name/hex spellings and a vpype pass. Unknown spellings pass through as-is."""
    if stroke is None:
        return 'none'
    s = stroke.strip().lower()
    if s in COLOR_NAMES:
        return COLOR_NAMES[s]
    if re.fullmatch(r'#[0-9a-f]{3}', s):     # #rgb -> #rrggbb
        return '#' + ''.join(ch * 2 for ch in s[1:])
    return s


def style_key(color, weight):
    """The stable string key for a (colour, weight) style, used by --map, the
    sidecar file, and the operator's summary."""
    return '{}@{:.2f}'.format(color, weight)


def normalize_map_key(k):
    """Normalise a --map key so 'red@3.0' and '#ff0000@3.00' select the same
    style, and a bare 'red' matches any weight of that colour. A 'COLOR@WEIGHT'
    key normalises both parts to style_key form; a bare 'COLOR' to hex."""
    if '@' in k:
        color, weight = k.split('@', 1)
        try:
            return style_key(_norm_color(color), float(weight))
        except ValueError:
            return k
    return _norm_color(k)


def _canvas_height(root):
    """Canvas height as parse_root computes it (needed by Path even when
    transform_origin is False)."""
    height_str = root.get('height')
    if height_str is None:
        return 0.0
    return float(height_str) if height_str.isnumeric() else float(height_str[:-2])


def parse_groups(root, transform_origin=False):
    """Parse the SVG into style groups, preserving document order.

    Mirrors svg_to_gcode.parse_root (same transform inheritance and Path
    handling) but, instead of a single flat curve list, buckets curves by their
    inherited (stroke colour, stroke width) -- one "style" per bucket. Both
    inherit down the tree exactly like presentation attributes in SVG, so a
    `<g stroke=... stroke-width=...>` sets the style for the shapes inside it.

    Returns an ordered list of (color, weight, curves) tuples -- one per distinct
    style, in first-appearance order. `color` is normalised hex; `weight` is a
    float.
    """
    ns = '{http://www.w3.org/2000/svg}'
    canvas_height = _canvas_height(root)

    groups = []      # ordered [(key, curves)]
    index = {}       # key -> curves list

    def bucket(key):
        curves = index.get(key)
        if curves is None:
            curves = []
            index[key] = curves
            groups.append((key, curves))
        return curves

    def recurse(element, transformation, stroke, width):
        for child in list(element):
            if _style_value(child, 'display') == 'none' or child.tag == ns + 'defs':
                continue

            child_t = deepcopy(transformation) if transformation else None
            transform = child.get('transform')
            if transform:
                child_t = Transformation() if child_t is None else child_t
                child_t.add_transform(transform)

            child_stroke = _element_stroke(child)
            child_stroke = stroke if child_stroke is None else child_stroke
            child_width = _element_stroke_width(child)
            child_width = width if child_width is None else child_width

            if child.tag == ns + 'path':
                path = Path(child.attrib['d'], canvas_height, transform_origin, child_t)
                w = child_width if child_width is not None else 1.0
                bucket((_norm_color(child_stroke), round(w, 3))).extend(path.curves)

            recurse(child, child_t, child_stroke, child_width)

    recurse(root, None, _element_stroke(root), _element_stroke_width(root))

    return [(key[0], key[1], curves) for key, curves in groups]


def _load_sidecar(svg_path):
    """Load the saved {style_key: pen} map beside the source SVG, or {}."""
    p = os.path.splitext(svg_path)[0] + '.pens.json'
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_sidecar(svg_path, pen_by_key):
    """Persist the {style_key: pen} map beside the source SVG so re-runs reuse
    it without prompting."""
    p = os.path.splitext(svg_path)[0] + '.pens.json'
    try:
        with open(p, 'w') as f:
            json.dump(pen_by_key, f, indent=2, sort_keys=True)
    except OSError as e:
        print('Note: could not save pen map to {}: {}'.format(p, e))


def resolve_pens(groups, svg_path, cli_pens=None, cli_map=None, assume_yes=False):
    """Assign a carousel pen to each style group and merge same-pen groups.

    Precedence per style, highest first:
      1. --pens N,N,... by group order (cli_pens).
      2. --map matching the style's colour+weight, then colour alone (cli_map).
      3. The saved sidecar (<svg>.pens.json).
      4. An interactive prompt (a tty and not --yes), defaulting to sequential.
      5. Otherwise sequential (group 1 -> pen 1, ...), capped at MAX_PEN.

    Saves the resolved map to the sidecar. Returns (passes, pen_styles):
      * passes     -- ordered [(pen, curves)], in first-needed order.
      * pen_styles -- pen -> comma-joined style keys drawn with it.
    """
    cli_pens = cli_pens or []
    cli_map = cli_map or {}
    sidecar = _load_sidecar(svg_path)

    keys = [style_key(color, weight) for color, weight, _ in groups]
    resolved = [None] * len(groups)
    from_prompt_default = [False] * len(groups)

    for i, (color, weight, _) in enumerate(groups):
        if i < len(cli_pens):
            resolved[i] = cli_pens[i]
        elif keys[i] in cli_map:
            resolved[i] = cli_map[keys[i]]
        elif color in cli_map:                 # colour-only --map entry
            resolved[i] = cli_map[color]
        elif keys[i] in sidecar:
            resolved[i] = int(sidecar[keys[i]])
        else:
            resolved[i] = min(i + 1, MAX_PEN)  # sequential default
            from_prompt_default[i] = True

    interactive = not assume_yes and sys.stdin.isatty()
    if interactive and any(from_prompt_default):
        print('Assign a carousel pen (1-{}) to each style. Enter accepts the '
              'default in brackets.'.format(MAX_PEN))
        for i, (color, weight, curves) in enumerate(groups):
            if not from_prompt_default[i]:
                continue
            prompt = '  {:<16} {:>5} segments -> pen? [{}] '.format(
                keys[i], len(curves), resolved[i])
            while True:
                ans = input(prompt).strip()
                if not ans:
                    break
                try:
                    n = int(ans)
                except ValueError:
                    print('    enter a number 1-{}'.format(MAX_PEN)); continue
                if 1 <= n <= MAX_PEN:
                    resolved[i] = n; break
                print('    pen must be 1-{}'.format(MAX_PEN))

    _save_sidecar(svg_path, {keys[i]: resolved[i] for i in range(len(groups))})

    passes = []       # ordered [(pen, curves)]
    by_pen = {}       # pen -> curves list
    pen_styles = {}   # pen -> [style_key, ...] in first-seen order
    for i, (color, weight, curves) in enumerate(groups):
        p = resolved[i]
        merged = by_pen.get(p)
        if merged is None:
            merged = []
            by_pen[p] = merged
            passes.append((p, merged))
            pen_styles[p] = []
        merged.extend(curves)
        if keys[i] not in pen_styles[p]:
            pen_styles[p].append(keys[i])

    return passes, {p: ', '.join(s) for p, s in pen_styles.items()}


# ---------------------------------------------------------------------------
# Curves --> polylines
# ---------------------------------------------------------------------------

def curves_to_polylines(curves):
    """Flatten svg_to_gcode curves into a list of polylines (lists of (x, y)).

    Each curve is approximated by straight segments; consecutive curves whose
    endpoints touch are merged into one continuous polyline (one pen-down run).
    """
    polylines = []
    current = None

    for curve in curves:
        chain = LineSegmentChain.line_segment_approximation(curve)
        segments = list(chain)
        if not segments:
            continue

        start = segments[0].start
        if current is None or _dist(current[-1], (start.x, start.y)) > JOIN_EPSILON:
            current = [(start.x, start.y)]
            polylines.append(current)

        for seg in segments:
            current.append((seg.end.x, seg.end.y))

    return polylines


def _dist(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


def rotate_polylines(polylines, deg):
    """Rotate every point CCW by `deg` about the origin. build_transform re-fits
    afterward, so the pivot is irrelevant -- only the orientation matters."""
    if deg % 360 == 0:
        return polylines
    rad = math.radians(deg)
    c, s = math.cos(rad), math.sin(rad)
    return [[(x * c - y * s, x * s + y * c) for (x, y) in poly] for poly in polylines]


# ---------------------------------------------------------------------------
# SVG space --> plotter units
# ---------------------------------------------------------------------------

def svg_canvas_bounds(root):
    """Return (min_x, min_y, max_x, max_y) of the SVG canvas, or None.

    Prefers the viewBox (which defines the user coordinate system the geometry
    lives in); falls back to width/height with a 0,0 origin. Returns None if
    neither is usable so the caller can fall back to the ink bounding box.
    """
    vb = root.get('viewBox')
    if vb:
        nums = [float(n) for n in re.findall(
            r'[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?', vb)]
        if len(nums) == 4 and nums[2] > 0 and nums[3] > 0:
            mnx, mny, w, h = nums
            return (mnx, mny, mnx + w, mny + h)
    num = r'([-+]?[0-9]*\.?[0-9]+)'
    w = root.get('width'); h = root.get('height')
    if w and h:
        wm = re.match(num, w); hm = re.match(num, h)
        if wm and hm:
            wv = float(wm.group(1)); hv = float(hm.group(1))
            if wv > 0 and hv > 0:
                return (0.0, 0.0, wv, hv)
    return None


def build_transform(polylines, src_bounds=None):
    """Return f(x, y) -> (ix, iy) mapping SVG coords into integer plotter units,
    scaled to fit the configured area (aspect preserved) with Y flipped.

    src_bounds, if given, is the (min_x, min_y, max_x, max_y) source rectangle to
    fit -- pass the SVG canvas to preserve the drawing's placement/margins instead
    of scaling the ink's bounding box up to fill the paper."""
    xs = [p[0] for poly in polylines for p in poly]
    ys = [p[1] for poly in polylines for p in poly]
    if not xs:
        raise ValueError('No drawable geometry found in SVG.')

    if src_bounds is not None:
        min_x, min_y, max_x, max_y = src_bounds
    else:
        min_x, max_x = min(xs), max(xs)
        min_y, max_y = min(ys), max(ys)
    src_w = max(max_x - min_x, 1e-9)
    src_h = max(max_y - min_y, 1e-9)

    avail_w = (plot_x_max - plot_x_min) - 2 * margin
    avail_h = (plot_y_max - plot_y_min) - 2 * margin
    scale = min(avail_w / src_w, avail_h / src_h)

    # Center the artwork within the available area.
    off_x = plot_x_min + margin + (avail_w - src_w * scale) / 2.0
    off_y = plot_y_min + margin + (avail_h - src_h * scale) / 2.0

    def transform(x, y):
        ix = off_x + (x - min_x) * scale
        # Flip Y: SVG origin is top-left, plotter origin is bottom-left.
        iy = off_y + (max_y - y) * scale
        return int(round(ix)), int(round(iy))

    return transform


# ---------------------------------------------------------------------------
# HP-GL record emission
# ---------------------------------------------------------------------------

def emit_records(pen_passes, transform):
    """Yield HP-GL instruction strings, each <= MAX_RECORD bytes (incl. ';').

    `pen_passes` is an ordered list of (pen, polylines): all of one pen's
    geometry, then a pen change (SP), then the next. The operator loads the pen
    matching each SP number into the carousel; between passes the pen is lifted
    (PU) before the change so no stray line is drawn while swapping.
    """
    yield 'IN;'

    for i, (pen_no, polylines) in enumerate(pen_passes):
        if i > 0:
            yield 'PU;'
        yield 'SP{};'.format(pen_no)

        for poly in polylines:
            pts = [transform(x, y) for (x, y) in poly]
            # Drop consecutive duplicate plotter-unit points (rounding collisions).
            deduped = [pts[0]]
            for pt in pts[1:]:
                if pt != deduped[-1]:
                    deduped.append(pt)

            x0, y0 = deduped[0]
            yield 'PU{},{};'.format(x0, y0)

            if len(deduped) < 2:
                # Degenerate polyline -- a single point at plotter resolution (the
                # source is a zero-length "dot" line, or a tiny shape that rounded
                # to one cell). Set the pen down on the spot so the dot isn't lost.
                yield 'PD{},{};'.format(x0, y0)
                continue

            # Pack the remaining points into one or more PD records. The pen stays
            # down across consecutive PD instructions, so a long polyline can be
            # split freely without lifting; each split just continues from the
            # current pen position.
            rec = 'PD'
            for (x, y) in deduped[1:]:
                token = '{},{}'.format(x, y)
                sep = '' if rec == 'PD' else ','
                # +1 for the trailing ';'
                if len(rec) + len(sep) + len(token) + 1 > MAX_RECORD:
                    yield rec + ';'
                    rec = 'PD' + token
                else:
                    rec += sep + token
            if rec != 'PD':
                yield rec + ';'

    yield 'PU;'
    yield 'SP0;'


# ---------------------------------------------------------------------------
# vpype optimisation pass
# ---------------------------------------------------------------------------

def _svg_page_size(svg_path):
    """(width, height) in user units from the SVG's width/height, else viewBox,
    else None. Used to tell vpype the page so it keeps the coordinate system."""
    try:
        root = ElementTree.parse(svg_path).getroot()
    except (OSError, ElementTree.ParseError):
        return None
    num = r'[-+]?[0-9]*\.?[0-9]+'
    w, h = root.get('width'), root.get('height')
    if w and h:
        wm, hm = re.match(num, w), re.match(num, h)
        if wm and hm:
            return float(wm.group(0)), float(hm.group(0))
    vb = root.get('viewBox')
    if vb:
        nums = re.findall(num, vb)
        if len(nums) == 4:
            return float(nums[2]), float(nums[3])
    return None


def optimize_with_vpype(in_path):
    """Run vpype linemerge/linesort to cut pen-up travel, returning the path of
    an optimised temp SVG, or None if vpype isn't installed or the run fails.

    Geometry is untouched (merge/sort only reorder and join touching paths), and
    each (colour, weight) group round-trips as its own vpype layer, so the style
    grouping this script keys on survives. Passing the source page size keeps the
    coordinate system 1:1."""
    vp = shutil.which('vpype')
    if vp is None:
        return None
    size = _svg_page_size(in_path)
    page = ['--page-size', '{:g}x{:g}'.format(*size)] if size else []
    out = tempfile.NamedTemporaryFile(suffix='.svg', delete=False).name
    cmd = [vp, 'read', in_path, 'linemerge', 'linesort', 'write', *page, out]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except (subprocess.CalledProcessError, OSError) as e:
        detail = getattr(e, 'stderr', '') or str(e)
        print('Note: vpype optimise failed ({}); converting the original.'.format(
            detail.strip().splitlines()[-1] if detail.strip() else e))
        return None
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

USAGE = """\
svg2hpgl.py -- convert an SVG into HP-GL records for an HP 7440A pen plotter.

Usage:
    python3 svg2hpgl.py <input.svg> [options]

Ink is grouped by style -- each distinct (stroke colour, stroke width) -- and
each style is assigned one carousel pen. With no assignment flags the styles are
listed and you're prompted for a pen each (default: sequential 1,2,3,...); the
choices are saved to <input>.pens.json and reused on the next run.

Options:
    --pens N,N,...           Assign pens to styles by their listed order
                             (e.g. --pens 1,3,2). Fills as many as given.
    --map STYLE=N            Assign pen N to a style. STYLE is 'COLOR@WEIGHT'
                             (e.g. '#ff0000@1.50=2') or just 'COLOR' to match any
                             weight of that colour. Repeatable.
    --pen N                  Draw everything on pen N, ignoring styles.
    -y, --yes                Don't prompt; use flags, the saved map, then the
                             sequential default. For scripts.
    --no-optimize            Skip the vpype linemerge/linesort pass.
    --canvas, --fit-canvas   Fit to the SVG canvas (viewBox / width x height),
                             preserving the drawing's placement and margins.
    --bounds, --fit-bounds   Fit the tight bounding box of the ink to the paper
                             (the default).
    -h, --help               Show this help and exit.

If vpype is on PATH it runs first (linemerge + linesort) to cut pen-up travel,
unless --no-optimize is given.

Output:
    Writes an .hgl record file to hpgl/ and prints the streaming command.\
"""


def print_help():
    print(USAGE)


def main():
    args = sys.argv[1:]

    if not args or any(a in ('-h', '--help') for a in args):
        print_help()
        return

    canvas = fit_to_canvas
    force_pen = None            # --pen N: ignore styles, draw everything on N
    cli_pens = None             # --pens N,N,...: assign by group order
    cli_map = {}                # --map STYLE=N: assign by style key or colour
    assume_yes = False
    optimize = True
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('--canvas', '--fit-canvas'):
            canvas = True
        elif a in ('--bounds', '--fit-bounds'):
            canvas = False
        elif a in ('-y', '--yes'):
            assume_yes = True
        elif a == '--no-optimize':
            optimize = False
        elif a == '--pen':
            i += 1
            force_pen = int(args[i])
        elif a.startswith('--pen='):
            force_pen = int(a.split('=', 1)[1])
        elif a in ('--pens', '--map'):
            i += 1
            val = args[i]
            if a == '--pens':
                cli_pens = [int(n) for n in val.split(',') if n.strip()]
            else:
                k, v = val.split('=', 1)
                cli_map[normalize_map_key(k)] = int(v)
        elif a.startswith('--pens='):
            cli_pens = [int(n) for n in a.split('=', 1)[1].split(',') if n.strip()]
        elif a.startswith('--map='):
            k, v = a.split('=', 1)[1].split('=', 1)
            cli_map[normalize_map_key(k)] = int(v)
        else:
            positional.append(a)
        i += 1
    in_path = positional[0] if positional else path

    # Optimise with vpype first (if available); keep the source path for the
    # sidecar so re-runs of the same drawing share one pen map.
    parse_path = in_path
    if optimize and force_pen is None:
        opt = optimize_with_vpype(in_path)
        if opt is not None:
            parse_path = opt
            print('Optimised with vpype (linemerge, linesort).')

    ElementTree.register_namespace('', 'http://www.w3.org/2000/svg')
    root = ElementTree.parse(parse_path).getroot()
    ns = '{http://www.w3.org/2000/svg}'

    normalize_primitives(root, ns)

    groups = parse_groups(root, transform_origin=False)
    if force_pen is not None:
        # Fold every style onto one pen (no pen changes).
        merged = [c for _, _, curves in groups for c in curves]
        pen_curve_passes = [(force_pen, merged)]
        pen_colours = {force_pen: 'forced --pen'}
    else:
        pen_curve_passes, pen_colours = resolve_pens(
            groups, in_path, cli_pens=cli_pens, cli_map=cli_map, assume_yes=assume_yes)

    pen_passes = []             # [(pen, polylines)]
    all_polylines = []
    for pen_no, curves in pen_curve_passes:
        polys = rotate_polylines(curves_to_polylines(curves), rotate)
        pen_passes.append((pen_no, polys))
        all_polylines.extend(polys)

    src_bounds = None
    if canvas:
        if rotate % 360 != 0:
            print('Note: --canvas ignored because rotate={} (canvas box does not '
                  'rotate with the geometry); fitting ink bounds instead.'.format(rotate))
        else:
            src_bounds = svg_canvas_bounds(root)
            if src_bounds is None:
                print('Note: --canvas requested but SVG has no usable viewBox/size; '
                      'fitting ink bounds instead.')
            else:
                print('Fitting to SVG canvas {}.'.format(src_bounds))
    transform = build_transform(all_polylines, src_bounds)
    records = list(emit_records(pen_passes, transform))

    # Sanity: no record may exceed the buffer budget.
    too_long = [r for r in records if len(r) > MAX_RECORD]
    if too_long:
        raise AssertionError('Records exceed MAX_RECORD: {!r}'.format(too_long[:3]))

    os.makedirs('hpgl', exist_ok=True)
    out = 'hpgl/gen_' + datetime.datetime.now().strftime('%y%m%d_%H%M%S') + '.hgl'
    with open(out, 'w') as f:
        f.write('\n'.join(records) + '\n')

    # Report the pen plan: what colour each pass draws and on which pen.
    if len(pen_passes) > 1:
        print('Multi-pen plot ({} pens):'.format(len(pen_passes)))
        for pen_no, polys in pen_passes:
            print('  SP{}  {:>4} polylines  ({})'.format(
                pen_no, len(polys), pen_colours.get(pen_no, '?')))

    draw_records = sum(1 for r in records if r.startswith('PD'))
    print('Wrote {} ({} records, {} PD, {} polylines, {} pen pass(es)).'.format(
        out, len(records), draw_records, len(all_polylines), len(pen_passes)))
    print('Stream it with:  python3 hpgl_stream.py {} <serial-port>'.format(out))


if __name__ == '__main__':
    main()
