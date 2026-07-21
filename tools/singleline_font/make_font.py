#!/usr/bin/env python3
"""Derive a single-line (stroke) font from Maple Mono Thin.

Pipeline per glyph:
  render filled glyph at high resolution (freetype)
  -> skeletonize (scikit-image) + distance transform (local stroke radius)
  -> build skeleton graph: endpoint/junction nodes, pixel-chain edges
  -> prune spurs, dissolve trivial junctions, merge chains through junctions
     by tangent continuity (long flowing strokes, e.g. 'x' = 2 strokes)
  -> extend stroke ends by local radius (skeleton stops short of caps)
  -> resample + gaussian smooth, split at corners
  -> fit cubic Beziers (Schneider) with prescribed end tangents; straight
     sections become true lines

Output: JSON (em-normalized, y-down, baseline at y=0) + PNG proof sheet.
"""

import json
import math
import os
import sys

import freetype
import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt, gaussian_filter1d
from skimage.morphology import skeletonize

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT = os.path.join(REPO, "MapleMono-TTF-AutoHint-patch", "MapleMono-Thin.ttf")
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
EM_PX = 800  # render resolution, pixels per em
GREEK_LOWER = [chr(c) for c in range(0x3B1, 0x3CA) if c != 0x3C2]  # alpha..omega, no final sigma
GREEK_UPPER = list("ΓΔΘΛΞΠΣΥΦΨΩ")  # only shapes distinct from Latin
MATH = list("∑∫√∞∂±×·≈≠≤≥→")
CHARS = [chr(c) for c in range(33, 127)] + GREEK_LOWER + GREEK_UPPER + MATH

# --- tunables (px at EM_PX resolution) ---
SPUR_FACTOR = 1.6        # spurs shorter than this * local radius are pruned
MICRO_EDGE_FACTOR = 1.0  # junction-junction edges shorter than this * stroke_w collapse
PAIR_COS = -0.5          # tangent dot threshold to merge chains through a junction (<=120 deg turn)
RESAMPLE_STEP = 2.0
SMOOTH_SIGMA = 2.0
CORNER_WINDOW_PX = 9.0
CORNER_ANGLE = math.radians(38)
FIT_TOL = 2.2            # max fit deviation px
LINE_TOL = 1.4           # max deviation to call a section a straight line
DOT_LEN_FACTOR = 1.3     # strokes shorter than this * stroke_w collapse to a dot
END_EXTEND = 0.92        # fraction of local radius to extend open ends


# ---------------------------------------------------------------- rendering

def render_glyph(face, ch):
    face.load_char(ch, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_NO_HINTING)
    g = face.glyph
    bm = g.bitmap
    buf = np.array(bm.buffer, dtype=np.uint8)  # fetch once: per-row access re-copies the whole buffer
    if bm.rows and bm.width:
        img = buf.reshape(bm.rows, bm.pitch)[:, :bm.width].copy()
    else:
        img = np.zeros((1, 1), dtype=np.uint8)
    # pad so skeleton/extension never hits the border
    pad = 8
    img = np.pad(img, pad)
    origin = (g.bitmap_left - pad, g.bitmap_top + pad)  # (x of col 0, rows above baseline of row 0)
    return img, origin


# ---------------------------------------------------------- skeleton graph

NBRS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def neighbors(skel, p):
    r, c = p
    out = []
    for dr, dc in NBRS:
        if skel[r + dr, c + dc]:
            out.append((r + dr, c + dc))
    return out


class Graph:
    """nodes: id -> dict(kind, pixels, centroid). chains: list of dicts
    (points: [(r,c)...], a: node id or None, b: node id or None)."""

    def __init__(self):
        self.nodes = {}
        self.chains = []


def build_graph(skel):
    from scipy.ndimage import label

    deg = np.zeros_like(skel, dtype=np.int8)
    pts = np.argwhere(skel)
    for r, c in pts:
        deg[r, c] = len(neighbors(skel, (r, c)))

    junction = skel & (deg >= 3)
    lab, n = label(junction, structure=np.ones((3, 3)))
    g = Graph()
    for i in range(1, n + 1):
        pix = [tuple(p) for p in np.argwhere(lab == i)]
        cen = tuple(np.mean(pix, axis=0))
        g.nodes[i] = {"kind": "junction", "pixels": set(pix), "centroid": cen}
    next_id = n + 1
    node_at = {}
    for nid, nd in g.nodes.items():
        for p in nd["pixels"]:
            node_at[p] = nid

    endpoints = [tuple(p) for p in pts if deg[tuple(p)] == 1 and tuple(p) not in node_at]
    for p in endpoints:
        g.nodes[next_id] = {"kind": "end", "pixels": {p}, "centroid": (float(p[0]), float(p[1]))}
        node_at[p] = next_id
        next_id += 1

    visited = set()  # regular (deg-2) pixels consumed by a chain

    def trace(start, prev):
        """walk from regular pixel `start` (coming from pixel `prev`) until a node pixel"""
        chain = [start]
        visited.add(start)
        cur, pre = start, prev
        while True:
            nxt = [q for q in neighbors(skel, cur) if q != pre and q not in visited or
                   (q in node_at and q != pre)]
            # prefer non-node continuation; a node pixel terminates
            node_n = [q for q in nxt if q in node_at]
            reg_n = [q for q in nxt if q not in node_at and q not in visited]
            if reg_n:
                pre, cur = cur, reg_n[0]
                chain.append(cur)
                visited.add(cur)
            elif node_n:
                return chain, node_at[node_n[0]], node_n[0]
            else:
                return chain, None, None

    # chains seeded from every node pixel's regular neighbors
    seeded = set()
    for nid, nd in g.nodes.items():
        for np_ in nd["pixels"]:
            for q in neighbors(skel, np_):
                if q in node_at or q in visited:
                    continue
                chain, endnode, endpix = trace(q, np_)
                key = (min(np_, chain[-1] if endpix is None else endpix),
                       max(np_, chain[-1] if endpix is None else endpix), len(chain))
                if key in seeded:
                    continue
                seeded.add(key)
                g.chains.append({"points": chain, "a": nid, "b": endnode})

    # pure cycles (no node at all, e.g. 'O')
    for p in map(tuple, pts):
        if p in visited or p in node_at:
            continue
        if deg[p] != 2:
            continue
        nb = neighbors(skel, p)
        chain, endnode, _ = trace(p, nb[0])
        # walk back the other way is unnecessary: a cycle returns near start
        g.chains.append({"points": chain, "a": None, "b": None, "cycle": True})

    # adjacent-node chains (two junction clusters touching) get zero-length chains: skip
    return g


def chain_len(points):
    return sum(math.dist(points[i], points[i + 1]) for i in range(len(points) - 1))


def prune_graph(g, dist, stroke_w):
    """iteratively remove short spurs, then dissolve deg-2 junctions and collapse micro edges"""
    changed = True
    rounds = 0
    while changed:
        rounds += 1
        if rounds > 500:
            print("  prune_graph: iteration cap hit", flush=True)
            break
        changed = False
        # spur pruning
        keep = []
        for ch in g.chains:
            a, b = ch["a"], ch["b"]
            is_spur = False
            if (a is None) != (b is None):
                pass
            kinds = [g.nodes[x]["kind"] if x is not None else None for x in (a, b)]
            if "junction" in kinds and ("end" in kinds or None in kinds):
                jn = g.nodes[a if kinds[0] == "junction" else b]
                L = chain_len(ch["points"])
                r_j = max(dist[p] for p in jn["pixels"])
                if L < SPUR_FACTOR * r_j:
                    is_spur = True
            if is_spur:
                changed = True
                # drop the endpoint node too
                for x, k in zip((ch["a"], ch["b"]), kinds):
                    if k == "end":
                        g.nodes.pop(x, None)
            else:
                keep.append(ch)
        g.chains = keep

        # collapse micro edges between two junction clusters into one junction
        # (X-crossings often skeletonize as two Y-junctions a few px apart)
        collapsed = False
        for i, ch in enumerate(g.chains):
            a, b = ch["a"], ch["b"]
            if (a is None or b is None or a == b or
                    g.nodes[a]["kind"] != "junction" or g.nodes[b]["kind"] != "junction"):
                continue
            if chain_len(ch["points"]) < MICRO_EDGE_FACTOR * stroke_w:
                na, nb = g.nodes[a], g.nodes[b]
                na["pixels"] |= nb["pixels"] | set(ch["points"])
                na["centroid"] = tuple(np.mean(list(na["pixels"]), axis=0))
                for other in g.chains:
                    for side in ("a", "b"):
                        if other[side] == b:
                            other[side] = a
                g.nodes.pop(b)
                g.chains.pop(i)
                changed = collapsed = True
                break
        if collapsed:
            continue

        # dissolve junctions that now touch exactly 2 chain ends
        incid = {}
        for i, ch in enumerate(g.chains):
            for side in ("a", "b"):
                nid = ch[side]
                if nid is not None and g.nodes[nid]["kind"] == "junction":
                    incid.setdefault(nid, []).append((i, side))
        for nid, ends in incid.items():
            if len(ends) == 2:
                (i, si), (j, sj) = ends
                if i == j:
                    # chain loops back to same junction; close it as a cycle
                    ch = g.chains[i]
                    ch["a"] = ch["b"] = None
                    ch["cycle"] = True
                    g.nodes.pop(nid, None)
                    changed = True
                    continue
                merged = merge_two(g.chains[i], si, g.chains[j], sj, g.nodes[nid]["centroid"])
                g.nodes.pop(nid, None)
                for k in sorted((i, j), reverse=True):
                    g.chains.pop(k)
                g.chains.append(merged)
                changed = True
                break  # indices invalidated; restart
    return g


def merge_two(ch1, side1, ch2, side2, centroid):
    """join two chains that meet at a junction; centroid inserted between"""
    p1 = ch1["points"] if side1 == "b" else list(reversed(ch1["points"]))
    a1 = ch1["a"] if side1 == "b" else ch1["b"]
    p2 = ch2["points"] if side2 == "a" else list(reversed(ch2["points"]))
    b2 = ch2["b"] if side2 == "a" else ch2["a"]
    cen = (centroid[0], centroid[1])
    return {"points": p1 + [cen] + p2, "a": a1, "b": b2}


def end_tangent(points, at_end, span):
    """unit tangent pointing away from the given end, averaged over span px"""
    pts = points if not at_end else list(reversed(points))
    if len(pts) < 2:
        return (0.0, 0.0)
    total, i = 0.0, 1
    while i < len(pts) - 1 and total < span:
        total += math.dist(pts[i - 1], pts[i])
        i += 1
    v = (pts[i][0] - pts[0][0], pts[i][1] - pts[0][1])
    n = math.hypot(*v) or 1.0
    return (v[0] / n, v[1] / n)


def merge_through_junctions(g, stroke_w):
    """pair chain-ends at each junction by tangent opposition -> long strokes"""
    changed = True
    rounds = 0
    while changed:
        rounds += 1
        if rounds > 500:
            print("  merge_through_junctions: iteration cap hit", flush=True)
            break
        changed = False
        incid = {}
        for i, ch in enumerate(g.chains):
            for side in ("a", "b"):
                nid = ch[side]
                if nid is not None and nid in g.nodes and g.nodes[nid]["kind"] == "junction":
                    incid.setdefault(nid, []).append((i, side))
        for nid, ends in incid.items():
            if len(ends) < 2:
                continue
            tangents = {}
            for (i, side) in ends:
                pts = g.chains[i]["points"]
                tangents[(i, side)] = end_tangent(pts, at_end=(side == "b"), span=max(stroke_w, 6))
            best, best_dot = None, PAIR_COS
            for x in range(len(ends)):
                for y in range(x + 1, len(ends)):
                    e1, e2 = ends[x], ends[y]
                    if e1[0] == e2[0]:
                        continue  # same chain: don't self-close here
                    t1, t2 = tangents[e1], tangents[e2]
                    d = t1[0] * t2[0] + t1[1] * t2[1]
                    if d < best_dot:
                        best_dot, best = d, (e1, e2)
            if best is None:
                continue
            (i, si), (j, sj) = best
            # orient: chain i ends INTO junction, chain j starts FROM junction
            si_in = "b" if si == "b" else "a"
            merged = merge_two(g.chains[i], si, g.chains[j], sj, g.nodes[nid]["centroid"])
            remaining = len(ends) - 2
            for k in sorted((i, j), reverse=True):
                g.chains.pop(k)
            g.chains.append(merged)
            if remaining == 0:
                g.nodes.pop(nid, None)
            changed = True
            break  # restart, indices invalid
    return g


def attach_leftover_junction_ends(g):
    """chains still ending at a junction get the centroid appended so strokes touch"""
    for ch in g.chains:
        for side in ("a", "b"):
            nid = ch[side]
            if nid is not None and nid in g.nodes and g.nodes[nid]["kind"] == "junction":
                cen = g.nodes[nid]["centroid"]
                if side == "a":
                    ch["points"].insert(0, cen)
                else:
                    ch["points"].append(cen)
                ch[side] = "attached"


# ------------------------------------------------------- resample / corners

def resample(points, step):
    pts = [(float(p[0]), float(p[1])) for p in points]
    if len(pts) < 2:
        return pts
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + math.dist(pts[i - 1], pts[i]))
    total = cum[-1]
    if total < 1e-6:
        return [pts[0]]
    n = max(int(round(total / step)), 1)
    out = []
    j = 0
    for k in range(n + 1):
        t = total * k / n
        while j < len(cum) - 2 and cum[j + 1] < t:
            j += 1
        seg = cum[j + 1] - cum[j]
        u = 0.0 if seg < 1e-9 else (t - cum[j]) / seg
        out.append((pts[j][0] + (pts[j + 1][0] - pts[j][0]) * u,
                    pts[j][1] + (pts[j + 1][1] - pts[j][1]) * u))
    return out


def smooth_chain(pts, closed, sigma):
    if len(pts) < 5:
        return pts
    arr = np.array(pts)
    mode = "wrap" if closed else "nearest"
    sm = np.stack([gaussian_filter1d(arr[:, 0], sigma, mode=mode),
                   gaussian_filter1d(arr[:, 1], sigma, mode=mode)], axis=1)
    if not closed:
        sm[0], sm[-1] = arr[0], arr[-1]  # pin endpoints
        # blend second/penultimate to avoid kink at pinned ends
        if len(pts) > 3:
            sm[1] = 0.5 * (arr[1] + sm[1])
            sm[-2] = 0.5 * (arr[-2] + sm[-2])
    return [tuple(p) for p in sm]


def find_corners(pts, closed, step):
    """indices of sharp turning points"""
    n = len(pts)
    w = max(int(round(CORNER_WINDOW_PX / step)), 2)
    if n < 2 * w + 1 and not closed:
        return []
    angles = np.zeros(n)
    for i in range(n):
        if closed:
            a, b, c = pts[(i - w) % n], pts[i], pts[(i + w) % n]
        else:
            if i < w or i >= n - w:
                continue
            a, b, c = pts[i - w], pts[i], pts[i + w]
        v1 = (b[0] - a[0], b[1] - a[1])
        v2 = (c[0] - b[0], c[1] - b[1])
        n1, n2 = math.hypot(*v1), math.hypot(*v2)
        if n1 < 1e-9 or n2 < 1e-9:
            continue
        d = max(-1.0, min(1.0, (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)))
        angles[i] = math.acos(d)
    corners = []
    for i in range(n):
        if angles[i] < CORNER_ANGLE:
            continue
        lo, hi = i - w, i + w
        window = [angles[j % n] if closed else angles[j] for j in range(max(lo, 0), min(hi + 1, n))]
        if angles[i] >= max(window):
            corners.append(i)
    # collapse adjacent corner indices
    out = []
    for i in corners:
        if out and abs(i - out[-1]) <= w:
            continue
        out.append(i)
    return out


# ------------------------------------------------------------ bezier fitting
# Schneider, "An Algorithm for Automatically Fitting Digitized Curves"

def fit_cubic(pts, t_hat1, t_hat2, err):
    """returns list of cubic segments [(p0, c1, c2, p3), ...]"""

    def bez_point(b, t):
        u = 1 - t
        return (u**3 * b[0][0] + 3 * u * u * t * b[1][0] + 3 * u * t * t * b[2][0] + t**3 * b[3][0],
                u**3 * b[0][1] + 3 * u * u * t * b[1][1] + 3 * u * t * t * b[2][1] + t**3 * b[3][1])

    def chord_params(pts):
        u = [0.0]
        for i in range(1, len(pts)):
            u.append(u[-1] + math.dist(pts[i - 1], pts[i]))
        total = u[-1] or 1.0
        return [x / total for x in u]

    def generate(pts, u, t1, t2):
        n = len(pts)
        A = [[(0.0, 0.0), (0.0, 0.0)] for _ in range(n)]
        for i in range(n):
            ui = u[i]
            b1 = 3 * ui * (1 - ui) ** 2
            b2 = 3 * ui * ui * (1 - ui)
            A[i][0] = (t1[0] * b1, t1[1] * b1)
            A[i][1] = (t2[0] * b2, t2[1] * b2)
        C = [[0.0, 0.0], [0.0, 0.0]]
        X = [0.0, 0.0]
        p0, p3 = pts[0], pts[-1]
        for i in range(n):
            ui = u[i]
            u1 = 1 - ui
            b0 = u1**3
            b1 = 3 * ui * u1 * u1
            b2 = 3 * ui * ui * u1
            b3 = ui**3
            tmp = (pts[i][0] - (b0 + b1) * p0[0] - (b2 + b3) * p3[0],
                   pts[i][1] - (b0 + b1) * p0[1] - (b2 + b3) * p3[1])
            C[0][0] += A[i][0][0] ** 2 + A[i][0][1] ** 2
            C[0][1] += A[i][0][0] * A[i][1][0] + A[i][0][1] * A[i][1][1]
            C[1][1] += A[i][1][0] ** 2 + A[i][1][1] ** 2
            X[0] += A[i][0][0] * tmp[0] + A[i][0][1] * tmp[1]
            X[1] += A[i][1][0] * tmp[0] + A[i][1][1] * tmp[1]
        C[1][0] = C[0][1]
        det = C[0][0] * C[1][1] - C[0][1] * C[1][0]
        alpha1 = alpha2 = 0.0
        if abs(det) > 1e-12:
            alpha1 = (X[0] * C[1][1] - X[1] * C[0][1]) / det
            alpha2 = (C[0][0] * X[1] - C[1][0] * X[0]) / det
        seg_len = math.dist(p0, p3)
        eps = 1e-6 * seg_len
        if alpha1 < eps or alpha2 < eps:
            alpha1 = alpha2 = seg_len / 3.0
        c1 = (p0[0] + t1[0] * alpha1, p0[1] + t1[1] * alpha1)
        c2 = (p3[0] + t2[0] * alpha2, p3[1] + t2[1] * alpha2)
        return (p0, c1, c2, p3)

    def max_error(pts, bez, u):
        worst, split = 0.0, len(pts) // 2
        for i in range(1, len(pts) - 1):
            p = bez_point(bez, u[i])
            d = math.dist(p, pts[i])
            if d > worst:
                worst, split = d, i
        return worst, split

    def reparameterize(pts, u, bez):
        def newton(p, t):
            b = bez
            d0 = bez_point(b, t)
            d1 = (3 * ((b[1][0] - b[0][0]) * (1 - t) ** 2 + 2 * (b[2][0] - b[1][0]) * (1 - t) * t + (b[3][0] - b[2][0]) * t * t),
                  3 * ((b[1][1] - b[0][1]) * (1 - t) ** 2 + 2 * (b[2][1] - b[1][1]) * (1 - t) * t + (b[3][1] - b[2][1]) * t * t))
            d2 = (6 * ((b[2][0] - 2 * b[1][0] + b[0][0]) * (1 - t) + (b[3][0] - 2 * b[2][0] + b[1][0]) * t),
                  6 * ((b[2][1] - 2 * b[1][1] + b[0][1]) * (1 - t) + (b[3][1] - 2 * b[2][1] + b[1][1]) * t))
            num = (d0[0] - p[0]) * d1[0] + (d0[1] - p[1]) * d1[1]
            den = d1[0] ** 2 + d1[1] ** 2 + (d0[0] - p[0]) * d2[0] + (d0[1] - p[1]) * d2[1]
            if abs(den) < 1e-12:
                return t
            return min(1.0, max(0.0, t - num / den))
        return [u[0]] + [newton(pts[i], u[i]) for i in range(1, len(pts) - 1)] + [u[-1]]

    def rec(pts, t1, t2, depth):
        if len(pts) == 2:
            d = math.dist(pts[0], pts[1]) / 3.0
            return [(pts[0], (pts[0][0] + t1[0] * d, pts[0][1] + t1[1] * d),
                     (pts[1][0] + t2[0] * d, pts[1][1] + t2[1] * d), pts[1])]
        u = chord_params(pts)
        bez = generate(pts, u, t1, t2)
        e, split = max_error(pts, bez, u)
        if e < err:
            return [bez]
        if e < err * 4:
            for _ in range(4):
                u = reparameterize(pts, u, bez)
                bez = generate(pts, u, t1, t2)
                e, split = max_error(pts, bez, u)
                if e < err:
                    return [bez]
        if depth > 12 or len(pts) < 4:
            return [bez]
        split = max(1, min(len(pts) - 2, split))
        # center tangent
        v = (pts[split - 1][0] - pts[split + 1][0], pts[split - 1][1] - pts[split + 1][1])
        n = math.hypot(*v) or 1.0
        tc = (v[0] / n, v[1] / n)
        left = rec(pts[:split + 1], t1, (tc[0], tc[1]), depth + 1)
        right = rec(pts[split:], (-tc[0], -tc[1]), t2, depth + 1)
        return left + right

    return rec(pts, t_hat1, t_hat2, 0)


def unit(v):
    n = math.hypot(*v) or 1.0
    return (v[0] / n, v[1] / n)


def section_to_cubics(pts, closed=False):
    """fit one corner-free section; returns list of cubic segs (or a line as degenerate cubic)"""
    if len(pts) < 2:
        return []
    # straight line?
    a, b = pts[0], pts[-1]
    ab = math.dist(a, b)
    if ab > 1e-6:
        max_dev = 0.0
        for p in pts[1:-1]:
            t = max(0.0, min(1.0, ((p[0] - a[0]) * (b[0] - a[0]) + (p[1] - a[1]) * (b[1] - a[1])) / (ab * ab)))
            q = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            max_dev = max(max_dev, math.dist(p, q))
        if max_dev < LINE_TOL and not closed:
            c1 = (a[0] + (b[0] - a[0]) / 3, a[1] + (b[1] - a[1]) / 3)
            c2 = (a[0] + (b[0] - a[0]) * 2 / 3, a[1] + (b[1] - a[1]) * 2 / 3)
            return [(a, c1, c2, b)]
    if closed:
        # seam tangent continuous across wrap
        t1 = unit((pts[1][0] - pts[-2][0], pts[1][1] - pts[-2][1]))
        t2 = (-t1[0], -t1[1])
    else:
        k = min(3, len(pts) - 1)
        t1 = unit((pts[k][0] - pts[0][0], pts[k][1] - pts[0][1]))
        t2 = unit((pts[-1 - k][0] - pts[-1][0], pts[-1 - k][1] - pts[-1][1]))
    return fit_cubic(pts, t1, t2, FIT_TOL)


# ---------------------------------------------------------------- per glyph

DOT_BBOX_EM = 0.17  # mask components smaller than this (both dims) become pen dots


def extract_glyph(face, ch):
    from scipy.ndimage import label

    img, (ox, oy) = render_glyph(face, ch)
    mask = img > 127
    if not mask.any():
        return [], img, (ox, oy)

    # small components (tittles, periods, colons) become dots, not strokes
    dot_strokes = []
    lab, ncomp = label(mask, structure=np.ones((3, 3)))
    for i in range(1, ncomp + 1):
        comp = lab == i
        rr, cc = np.nonzero(comp)
        if (rr.max() - rr.min()) < DOT_BBOX_EM * EM_PX and (cc.max() - cc.min()) < DOT_BBOX_EM * EM_PX:
            w = img[comp].astype(np.float64)
            cen = (float((rr * w).sum() / w.sum()), float((cc * w).sum() / w.sum()))
            dot_strokes.append({"dot": cen})
            mask = mask & ~comp
    if not mask.any():
        return dot_strokes, img, (ox, oy)

    skel = skeletonize(mask)
    dist = {}
    dt = distance_transform_edt(mask)
    stroke_w = 2.0 * float(np.median(dt[skel])) if skel.any() else 4.0

    dist_map = dt

    g = build_graph(skel)
    dget = lambda p: float(dt[int(round(p[0])), int(round(p[1]))])

    class D:
        def __getitem__(self, p):
            return dget(p)
    g = prune_graph(g, D(), stroke_w)
    g = merge_through_junctions(g, stroke_w)
    attach_leftover_junction_ends(g)

    strokes = list(dot_strokes)
    for ch_ in g.chains:
        pts = ch_["points"]
        closed = bool(ch_.get("cycle"))
        if closed and len(pts) > 2:
            pts = pts + [pts[0]]
        L = chain_len(pts)
        if L < DOT_LEN_FACTOR * stroke_w:
            cen = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
            strokes.append({"dot": cen})
            continue
        # extend open free ends by local radius
        pf = [(float(p[0]), float(p[1])) for p in pts]
        if not closed:
            for end, node in ((0, ch_["a"]), (-1, ch_["b"])):
                if node == "attached":
                    continue
                r = dget(pf[end]) * END_EXTEND
                t = end_tangent(pf, at_end=(end == -1), span=max(stroke_w, 6))
                pf_end = pf[end]
                newp = (pf_end[0] - t[0] * r, pf_end[1] - t[1] * r)
                if end == 0:
                    pf.insert(0, newp)
                else:
                    pf.append(newp)
        rs = resample(pf, RESAMPLE_STEP)
        if len(rs) < 2:
            cen = rs[0] if rs else pf[0]
            strokes.append({"dot": cen})
            continue
        sm = smooth_chain(rs, closed, SMOOTH_SIGMA)
        corners = find_corners(sm, closed, RESAMPLE_STEP)
        cubics = []
        if closed and not corners:
            segs = section_to_cubics(sm, closed=True)
            strokes.append({"closed": True, "cubics": segs})
            continue
        if closed and corners:
            # rotate so chain starts/ends at first corner, then treat as open
            i0 = corners[0]
            sm = sm[i0:-1] + sm[:i0 + 1]
            corners = sorted((c - i0) % (len(sm) - 1) for c in corners)
            closed = False
            if corners and corners[0] == 0:
                corners = corners[1:]
            corners = [c for c in corners if 0 < c < len(sm) - 1]
        cuts = [0] + corners + [len(sm) - 1]
        for i in range(len(cuts) - 1):
            sec = sm[cuts[i]:cuts[i + 1] + 1]
            cubics.extend(section_to_cubics(sec))
        strokes.append({"closed": False, "cubics": cubics})
    return strokes, img, (ox, oy)


# ------------------------------------------------------------------- output

def to_em(p, origin):
    ox, oy = origin
    return ((p[1] + ox) / EM_PX, (p[0] - oy) / EM_PX)  # (row,col) -> (x, y-down)


def bez_flat(b, n=24):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((u**3 * b[0][0] + 3 * u * u * t * b[1][0] + 3 * u * t * t * b[2][0] + t**3 * b[3][0],
                    u**3 * b[0][1] + 3 * u * u * t * b[1][1] + 3 * u * t * t * b[2][1] + t**3 * b[3][1]))
    return out


def main():
    face = freetype.Face(FONT)
    face.set_pixel_sizes(0, EM_PX)
    adv_em = 0.6  # maple mono monospace advance 600/1000

    only = sys.argv[1] if len(sys.argv) > 1 else None
    chars = list(only) if only else CHARS

    glyphs = {}
    cell = int(os.environ.get("PROOF_CELL", "260"))
    scale = cell / EM_PX * 0.72
    cols = 10
    rows = (len(chars) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * cell), "white")
    drw = ImageDraw.Draw(sheet)
    palette = [(220, 40, 40), (30, 110, 220), (20, 150, 60), (200, 120, 0), (150, 40, 180), (0, 150, 150)]

    import time as _time
    for idx, ch in enumerate(chars):
        t0 = _time.time()
        print(f"{ch!r}...", end=" ", flush=True)
        strokes, img, origin = extract_glyph(face, ch)
        print(f"{_time.time() - t0:.1f}s", end=" ", flush=True)
        gx = (idx % cols) * cell
        gy = (idx // cols) * cell
        # faint original
        h, w = img.shape
        if img.size and img.max() > 0:
            small = Image.fromarray((255 - (img.astype(np.float32) * 0.25)).astype(np.uint8), "L")
            sw, sh = max(int(w * scale), 1), max(int(h * scale), 1)
            small = small.resize((sw, sh))
            # position: baseline at 0.78*cell, x origin at 0.2*cell
            px = gx + int(0.2 * cell + origin[0] * scale)
            py = gy + int(0.78 * cell - origin[1] * scale)
            sheet.paste(Image.merge("RGB", (small, small, small)), (px, py))
        # strokes
        out_strokes = []
        for si, st in enumerate(strokes):
            color = palette[si % len(palette)]
            if "dot" in st:
                p = to_em(st["dot"], origin)
                out_strokes.append({"dot": [round(p[0], 4), round(p[1], 4)]})
                cxp = gx + 0.2 * cell + p[0] * cell * 0.72
                cyp = gy + 0.78 * cell + p[1] * cell * 0.72
                drw.ellipse([cxp - 3, cyp - 3, cxp + 3, cyp + 3], fill=color)
                continue
            cubs = []
            flat_px = []
            for b in st["cubics"]:
                bem = [to_em(p, origin) for p in b]
                cubs.append([[round(v, 4) for v in p] for p in bem])
                flat_px.extend(bez_flat(bem))
            out_strokes.append({"closed": st["closed"], "cubics": cubs})
            pts = [(gx + 0.2 * cell + x * cell * 0.72, gy + 0.78 * cell + y * cell * 0.72) for x, y in flat_px]
            if len(pts) > 1:
                drw.line(pts, fill=color, width=2)
            # mark on-curve nodes
            for b in st["cubics"]:
                for p in (b[0], b[3]):
                    x, y = to_em(p, origin)
                    cxp = gx + 0.2 * cell + x * cell * 0.72
                    cyp = gy + 0.78 * cell + y * cell * 0.72
                    drw.ellipse([cxp - 2, cyp - 2, cxp + 2, cyp + 2], outline=(0, 0, 0))
        glyphs[ch] = {"advance": adv_em, "strokes": out_strokes}
        nseg = sum(len(s.get("cubics", [])) for s in out_strokes)
        print(f"{ch!r}: {len(out_strokes)} strokes, {nseg} cubics")

    with open(os.path.join(OUT_DIR, "font.json"), "w") as f:
        json.dump({"em": 1.0, "advance": adv_em, "cap": 0.73, "xheight": 0.55,
                   "ascent": 0.83, "descent": 0.22, "glyphs": glyphs}, f)
    sheet.save(os.path.join(OUT_DIR, "proof.png"))
    print("wrote font.json, proof.png")


if __name__ == "__main__":
    main()
