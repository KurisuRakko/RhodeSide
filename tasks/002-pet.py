#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
任务 002：pet.html（Rhodeside 桌宠调试模式）冒烟测试。

跑法：/home/rakko/Collection/MoodleAnaly/.venv/bin/python tasks/002-pet.py
前提：9334 上有一个带 WebGL 的无头 Chrome；8066 vite dev 在跑。只读页面，不改任何 web/ 文件。

依次打开三页（视口 600x600），每页等 ~6s，记录 console 的 error/warn 与 [rhodeside ←] 消息，
用 canvas#pet.toDataURL('image/png') 取带真实 alpha 的画布，落到 tasks/002-shots/。
再在第一页里调 receive({type:'face', dir:-1}) 验证水平翻转 + 不裁边。
"""

import base64
import importlib.util
import json
import os
import re
import sys
import time
from urllib.parse import quote

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "002-shots")
CDP = "http://127.0.0.1:9334"
BASE = "http://127.0.0.1:8066"
MODEL = "荒芜拉普兰德"
VIEWPORT = {"width": 600, "height": 600}
THR = 40  # alpha 前景阈值，与 001-verify.py 一致


def _load_v001():
    spec = importlib.util.spec_from_file_location("verify001", os.path.join(HERE, "001-verify.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


v001 = _load_v001()


def page_url(outfit=None, group="基建", height=None):
    qs = [("model", MODEL)]
    if outfit:
        qs.append(("outfit", outfit))
    if group is not None:
        qs.append(("group", group))
    if height is not None:
        qs.append(("height", str(height)))
    return BASE + "/pet.html?" + "&".join(f"{k}={quote(str(v))}" for k, v in qs)


# ------------------------------------------------------------------ console 记录

def make_recorder():
    rec = {"rhodeside": [], "errors": [], "warnings": [], "other": []}

    def on_console(m):
        try:
            args = m.args
            first = args[0].json_value() if args else None
        except Exception:
            first = None
        is_rhodeside = (first == "[rhodeside ←]") or ("[rhodeside \u2190]" in (m.text or ""))
        if is_rhodeside:
            obj = None
            try:
                if len(m.args) > 1:
                    obj = m.args[1].json_value()
            except Exception:
                obj = None
            if not isinstance(obj, dict):
                txt = m.text or ""
                i = txt.find("{")
                if i >= 0:
                    try:
                        obj = json.loads(txt[i:])
                    except Exception:
                        obj = {"_raw": txt}
                else:
                    obj = {"_raw": txt}
            rec["rhodeside"].append(obj)
            return
        t = m.type
        entry = {"type": t, "text": (m.text or "")[:400]}
        if t == "error":
            rec["errors"].append(entry)
        elif t in ("warning", "warn"):
            rec["warnings"].append(entry)
        else:
            rec["other"].append(entry)

    return rec, on_console


def find_msg(rec, typ):
    for m in rec["rhodeside"]:
        if m.get("type") == typ:
            return m
    return None


# ------------------------------------------------------------------ 图像分析

def alpha_stats(path, thr=THR):
    """全分辨率 alpha 统计 + 前景 bbox/质心。"""
    im = Image.open(path).convert("RGBA")
    W, H = im.size
    a = im.getchannel("A").tobytes()
    n = W * H
    zero = sub = fg = 0
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    sx = sy = 0.0
    for i in range(n):
        v = a[i]
        if v == 0:
            zero += 1
        elif v < thr:
            sub += 1
        else:
            fg += 1
            x = i % W
            y = i // W
            sx += x
            sy += y
            if x < x0:
                x0 = x
            if x > x1:
                x1 = x
            if y < y0:
                y0 = y
            if y > y1:
                y1 = y
    ap = im.getchannel("A").load()
    corners = [ap[0, 0], ap[W - 1, 0], ap[0, H - 1], ap[W - 1, H - 1]]
    # 四边最外 3 像素环的最大 alpha
    ring = 0
    for x in range(W):
        for y in (0, 1, 2, H - 3, H - 2, H - 1):
            v = ap[x, y]
            if v > ring:
                ring = v
    for y in range(H):
        for x in (0, 1, 2, W - 3, W - 2, W - 1):
            v = ap[x, y]
            if v > ring:
                ring = v
    # 左右边缘列最大 alpha（翻转裁边判据）
    left = right = 0
    for y in range(H):
        for x in (0, 1):
            v = ap[x, y]
            if v > left:
                left = v
        for x in (W - 2, W - 1):
            v = ap[x, y]
            if v > right:
                right = v
    m = {
        "size": f"{W}x{H}",
        "alpha_zero": zero,
        "alpha_sub_thr": sub,
        "fg_px": fg,
        "fg_frac": round(fg / n, 4),
        "bg_frac": round((zero + sub) / n, 4),
        "bbox": [x0, y0, x1, y1] if fg else [0, 0, 0, 0],
        "row_bottom": y1 if fg else None,
        "row_top": y0 if fg else None,
        "col_left": x0 if fg else None,
        "col_right": x1 if fg else None,
        "centroid": [round(sx / fg, 2), round(sy / fg, 2)] if fg else None,
        "corners_alpha": corners,
        "border_ring_max_alpha": ring,
        "edge_col_left_max_alpha": left,
        "edge_col_right_max_alpha": right,
    }
    return m, im, W, H, a


def mask_from_alpha(a, thr=THR):
    return [1 if v >= thr else 0 for v in a]


def iou(m1, m2):
    inter = uni = 0
    for x, y in zip(m1, m2):
        if x or y:
            uni += 1
            if x and y:
                inter += 1
    return round(inter / uni, 4) if uni else 1.0


def mirror_mask(mask, W, H):
    out = [0] * (W * H)
    for i, v in enumerate(mask):
        if v:
            x = i % W
            y = i // W
            out[y * W + (W - 1 - x)] = 1
    return out


def connected_transparent(mask_bg, W, H, scale=0.5):
    """透明像素（alpha 掩码取反）的连通域：最大一块是否触到四边。"""
    w = max(1, int(W * scale))
    h = max(1, int(H * scale))
    # 最近邻降采样
    small = bytearray(w * h)
    for y in range(h):
        sy = min(H - 1, int(y / scale))
        for x in range(w):
            sx = min(W - 1, int(x / scale))
            small[y * w + x] = 0 if mask_bg[sy * W + sx] else 1  # 1 = 透明
    seen = bytearray(w * h)
    best = 0
    touches = False
    for start in range(w * h):
        if small[start] and not seen[start]:
            stack = [start]
            seen[start] = 1
            n = 0
            t = False
            while stack:
                j = stack.pop()
                n += 1
                x = j % w
                y = j // w
                if x == 0 or y == 0 or x == w - 1 or y == h - 1:
                    t = True
                for yy in range(max(0, y - 1), min(h, y + 2)):
                    base = yy * w
                    for xx in range(max(0, x - 1), min(w, x + 2)):
                        k = base + xx
                        if small[k] and not seen[k]:
                            seen[k] = 1
                            stack.append(k)
            if n > best:
                best = n
                touches = t
    return {"bg_components_biggest_frac": round(best / (w * h), 4), "biggest_touches_border": touches}


# ------------------------------------------------------------------ 单页测试

def shot(page, path):
    b64 = page.eval_on_selector("#pet", "c => c.toDataURL('image/png')")
    raw = base64.b64decode(b64.split(",", 1)[1])
    with open(path, "wb") as f:
        f.write(raw)
    return raw


def run_page(page, idx, url, wait_ms=6000, do_flip=False):
    rec, on_console = make_recorder()
    page.on("console", on_console)
    pageerrors = []
    page.on("pageerror", lambda e: pageerrors.append(str(e)))
    failed = []
    page.on("requestfailed", lambda r: failed.append(f"{r.url} :: {r.failure}"))
    badresp = []

    def on_response(r):
        if r.status >= 400:
            badresp.append(f"{r.status} {r.url}")

    page.on("response", on_response)

    result = {"idx": idx, "url": url}
    t0 = time.time()
    page.goto(url, wait_until="domcontentloaded")
    try:
        page.wait_for_function("!!(window.__pet && window.__pet.layout)", timeout=15000)
        result["loaded_seen"] = True
    except Exception:
        result["loaded_seen"] = False

    # 等到从导航起 ~wait_ms
    remain = wait_ms - int((time.time() - t0) * 1000)
    if remain > 0:
        page.wait_for_timeout(remain)

    loaded = find_msg(rec, "loaded")
    ready = find_msg(rec, "ready")
    result["rhodeside_types"] = [m.get("type") for m in rec["rhodeside"]]
    result["ready"] = ready
    result["loaded"] = loaded
    result["layout_live"] = page.evaluate("window.__pet.layout")
    result["canvas_size"] = page.eval_on_selector("#pet", "c => c.width + 'x' + c.height")
    result["dpr"] = page.evaluate("window.devicePixelRatio")
    result["console_errors"] = rec["errors"]
    result["console_warnings"] = rec["warnings"]
    result["pageerrors"] = pageerrors
    result["requestfailed"] = failed
    result["bad_responses"] = badresp
    if rec["other"]:
        result["console_other_count"] = len(rec["other"])

    outfit = (loaded or {}).get("outfit") or "?" 
    group = (loaded or {}).get("group") or "?"
    safe = re.sub(r"[^\w\u4e00-\u9fff.-]+", "_", f"{outfit}-{group}")
    path = os.path.join(SHOTS, f"{idx}-{safe}.png")
    shot(page, path)
    result["shot"] = os.path.basename(path)

    layout = result["layout_live"] or (loaded or {}).get("layout") or {}
    stats, im, W, H, a = alpha_stats(path)
    stats["n_comp"] = v001.analyze_alpha(path, scale=0.5)
    # 脚底位置：图像最低非透明行 vs 画布底边往上 footY
    foot_y = layout.get("footY")
    if foot_y is not None and stats["row_bottom"] is not None:
        expected = H - foot_y
        stats["footY"] = round(foot_y, 2)
        stats["expected_bottom_row"] = round(expected, 2)
        stats["bottom_row_minus_expected"] = round(stats["row_bottom"] - expected, 2)
    if stats["centroid"]:
        stats["centroid_offset_x_from_center"] = round(stats["centroid"][0] - W / 2, 2)
    stats["transparent_components"] = connected_transparent(mask_from_alpha(a), W, H)
    result["stats"] = stats
    result["verdict"] = v001.verdict(stats["n_comp"])

    if do_flip:
        result["flip"] = run_flip(page, idx, safe, a, W, H, rec)

    page.remove_listener("console", on_console)
    return result


def run_flip(page, idx, safe, a_before, W, H, rec):
    """第一页：face dir=-1 → 等 1s → 再取一张；外加冻结动画的镜像对照。"""
    out = {}
    m_before = mask_from_alpha(a_before)
    out["shot_before"] = f"{idx}-{safe}.png"

    page.evaluate("window.__pet.receive({type:'face', dir:-1})")
    t = time.time()
    page.wait_for_timeout(1000)
    p_after = os.path.join(SHOTS, f"{idx}-flip-{safe}.png")
    shot(page, p_after)
    out["shot_after"] = os.path.basename(p_after)
    out["waited_ms"] = int((time.time() - t) * 1000)
    out["faced_msg"] = find_msg(rec, "faced")

    stats_after, _im_after, _W2, _H2, a_after = alpha_stats(p_after)
    m_after = mask_from_alpha(a_after)
    out["after_stats"] = stats_after
    out["iou_before_after"] = iou(m_before, m_after)
    out["iou_mirror_before_after"] = iou(mirror_mask(m_before, W, H), m_after)
    sb, _imb, _Wb, _Hb, _ab = alpha_stats(os.path.join(SHOTS, out["shot_before"]))
    out["centroid_before"] = sb["centroid"][0] if sb["centroid"] else None
    out["centroid_after"] = stats_after["centroid"][0] if stats_after["centroid"] else None
    if out["centroid_before"] is not None and out["centroid_after"] is not None:
        out["centroid_predicted_after"] = round(W - out["centroid_before"], 2)
        out["centroid_pred_err"] = round(out["centroid_after"] - (W - out["centroid_before"]), 2)
    out["edge_left_after"] = stats_after["edge_col_left_max_alpha"]
    out["edge_right_after"] = stats_after["edge_col_right_max_alpha"]

    # 额外：冻结动画后的纯镜像对照（speed=0 让姿态不动，翻转可直接镜像比对）
    page.evaluate("window.__pet.receive({type:'speed', value:0})")
    page.evaluate("window.__pet.receive({type:'face', dir:1})")
    page.wait_for_timeout(500)
    p_dir1 = os.path.join(SHOTS, f"{idx}-frozen-dir1.png")
    shot(page, p_dir1)
    page.evaluate("window.__pet.receive({type:'face', dir:-1})")
    page.wait_for_timeout(500)
    p_dirn1 = os.path.join(SHOTS, f"{idx}-frozen-dir-1.png")
    shot(page, p_dirn1)
    m1 = mask_from_alpha(alpha_stats(p_dir1)[4])
    mn1 = mask_from_alpha(alpha_stats(p_dirn1)[4])
    out["frozen_iou_same"] = iou(m1, mn1)
    out["frozen_iou_mirror"] = iou(mirror_mask(m1, W, H), mn1)
    out["frozen_shot_dir1"] = os.path.basename(p_dir1)
    out["frozen_shot_dir-1"] = os.path.basename(p_dirn1)
    # 解除冻结，别影响后续页面
    page.evaluate("window.__pet.receive({type:'speed', value:1})")
    page.evaluate("window.__pet.receive({type:'face', dir:1})")
    return out


def main():
    os.makedirs(SHOTS, exist_ok=True)
    cases = [
        (1, page_url(group="基建"), True),
        (2, page_url(outfit="char_1038_whitw2_sale_15", group="基建"), False),
        (3, page_url(group="正面"), False),
    ]
    report = {"pages": []}
    with sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(CDP)
        ctx = browser.new_context(viewport=VIEWPORT, device_scale_factor=1)
        for idx, url, flip in cases:
            pg = ctx.new_page()
            r = run_page(pg, idx, url, wait_ms=6000, do_flip=flip)
            pg.close()
            report["pages"].append(r)
            print(f"[page {idx}] {r['verdict']} url={r['url']} shot={r['shot']} types={r['rhodeside_types']} "
                  f"errors={len(r['console_errors'])} warns={len(r['console_warnings'])}", flush=True)
        ctx.close()
        browser.close()

    with open(os.path.join(SHOTS, "results.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    sys.exit(main())
