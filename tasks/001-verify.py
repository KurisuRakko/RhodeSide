#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
任务 001 验收脚本：荒芜拉普兰德（2 时装 × 正面/背面/基建）+ 贴图缩放兜底路径。

跑法：/home/rakko/Collection/MoodleAnaly/.venv/bin/python tasks/001-verify.py
前提：9334 上有一个带 WebGL 的无头 Chrome；8066 vite dev 在跑。

三条路径：
  normal   ：真实浏览器（createImageBitmap 支持 resizeWidth/Height）
  fallback ：init script 把 resizeWidth/Height/Quality 从 options 里删掉，
             模拟不认 resize 的浏览器 → 逼 engine.decode() 走 canvas 拉伸兜底
  broken   ：init script 把 gl.MAX_TEXTURE_SIZE 伪造成 64 → engine 的 fitSize() 返回 undefined，
             decode() 直接返回缩小版贴图 → 复现修复前的「碎」现象，用作判据标定

截图（画布本身带 alpha，另存一份 stage 合成图）：
  tasks/001-shots/<时装>-<组>.png           合成图（人看）
  tasks/001-shots/<时装>-<组>-alpha.png     画布 toDataURL（真实 alpha，脚本判据用）
"""

import base64
import json
import os
import re
import sys
import time
from urllib.parse import quote

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "001-shots")
CDP = "http://127.0.0.1:9334"
BASE = "http://127.0.0.1:8066"
MODEL = "荒芜拉普兰德"
URL = f"{BASE}/?model={quote(MODEL)}"
OUTFITS = ["char_1038_whitw2", "char_1038_whitw2_sale_15"]
GROUPS = ["正面", "背面", "基建"]

# init script：STRIP 删 resize 选项；BROKEN 伪造 MAX_TEXTURE_SIZE。
INIT_SCRIPT = r"""
(() => {
  const STRIP = __STRIP__, BROKEN = __BROKEN__;
  window.__cib = [];
  const orig = window.createImageBitmap;
  if (orig) {
    window.createImageBitmap = function (img, ...rest) {
      let opts = (rest.length === 1 && rest[0] && typeof rest[0] === 'object') ? { ...rest[0] } : rest[0];
      const hadResize = !!(opts && typeof opts === 'object' && (opts.resizeWidth || opts.resizeHeight));
      const input = (img && typeof img === 'object' && img.width !== undefined) ? (img.width + 'x' + img.height) : (typeof img + (img && img.size ? ':' + img.size : ''));
      if (STRIP && opts && typeof opts === 'object') {
        delete opts.resizeWidth; delete opts.resizeHeight; delete opts.resizeQuality;
      }
      const args = (rest.length === 1 && rest[0] && typeof rest[0] === 'object') ? [opts] : rest;
      return orig.call(window, img, ...args).then((b) => {
        window.__cib.push({ hadResize, in: input, out: b.width + 'x' + b.height });
        return b;
      });
    };
  }
  if (BROKEN) {
    const gp = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function (p) {
      if (p === 0x0D33) return 64;  /* MAX_TEXTURE_SIZE */
      return gp.call(this, p);
    };
  }
})();
"""


def init_script(strip=False, broken=False):
    return INIT_SCRIPT.replace("__STRIP__", "true" if strip else "false").replace(
        "__BROKEN__", "true" if broken else "false"
    )


# ------------------------------------------------------------------ 页面操作

def seg_click(page, text):
    for el in page.query_selector_all("span.rk-segment"):
        if (el.inner_text() or "").strip() == text:
            el.click()
            page.wait_for_timeout(200)
            return True
    raise RuntimeError(f"找不到 rk-segment: {text}")


def pick(page, label, text, timeout=8.0):
    page.click(f'button[aria-label="{label}"]')
    deadline = time.time() + timeout
    while time.time() < deadline:
        opts = page.locator('[role="option"]:visible')
        for i in range(opts.count()):
            el = opts.nth(i)
            try:
                if (el.inner_text() or "").strip() == text:
                    el.click()
                    page.wait_for_timeout(250)
                    page.keyboard.press("Escape")
                    page.wait_for_timeout(150)
                    return True
            except Exception:
                pass
        page.wait_for_timeout(120)
    raise RuntimeError(f"下拉 {label} 里找不到选项 {text}")


def loop_off(page):
    """关掉循环播放，让非循环动画停在末帧，截图才可复现/可比对。"""
    sw = page.locator("label.ss-switch", has_text="循环播放").locator('[role="switch"]')
    if sw.count() == 0:
        return False
    if sw.first.get_attribute("aria-checked") == "true":
        sw.first.click()
        page.wait_for_timeout(250)
    return True


def anim_info(page):
    btn = page.query_selector('button[aria-label="动画"]')
    if not btn:
        return None, None
    txt = (btn.inner_text() or "").replace("\n", " ")
    m = re.search(r"([\d.]+)s", txt)
    return txt.strip(), (float(m.group(1)) if m else None)


def capture(page, tag):
    os.makedirs(SHOTS, exist_ok=True)
    page.locator(".ss-stage").screenshot(path=os.path.join(SHOTS, tag + ".png"))
    b64 = page.eval_on_selector("canvas.ss-canvas", "c => c.toDataURL('image/png')")
    raw = base64.b64decode(b64.split(",", 1)[1])
    with open(os.path.join(SHOTS, tag + "-alpha.png"), "wb") as f:
        f.write(raw)
    size = page.eval_on_selector("canvas.ss-canvas", "c => c.width + 'x' + c.height")
    return size


def wait_and_shot(page, tag, base_wait=5.0):
    """等到循环关闭后动画走到末帧，再截图。"""
    page.wait_for_selector('button[aria-label="动画"]', timeout=20000)
    label, dur = anim_info(page)
    wait = base_wait
    if dur and dur + 1.5 > wait:
        wait = dur + 1.5
    page.wait_for_timeout(int(wait * 1000) + 200)
    size = capture(page, tag)
    return {"tag": tag, "anim": label, "duration": dur, "waited": round(wait, 2), "canvas": size}


def run(page, name, cases, events):
    """cases: [(outfit, group, tag)]"""
    errors, warns = [], []
    page.on("console", lambda m: (errors if m.type == "error" else warns).append(m.text))
    page.on("pageerror", lambda e: errors.append("pageerror: " + str(e)))
    page.goto(URL, wait_until="domcontentloaded")
    page.wait_for_timeout(8000)

    body = page.evaluate("document.body.innerText")
    onscreen = [ln for ln in body.splitlines() if any(k in ln for k in ("失败", "错误", "没法", "不支持", "载入"))]

    seg_click(page, "查看")
    loop_off(page)

    results = []
    for outfit, group, tag in cases:
        rec = {"run": name, "outfit": outfit, "group": group, "tag": tag}
        try:
            pick(page, "时装组", outfit)
            page.wait_for_timeout(1200)
            pick(page, "模型组", group)
            rec.update(wait_and_shot(page, tag))
            rec["ok"] = True
        except Exception as e:  # noqa: BLE001
            rec["ok"] = False
            rec["error"] = str(e)
            try:
                page.locator(".ss-stage").screenshot(path=os.path.join(SHOTS, tag + "-FAIL.png"))
            except Exception:
                pass
        results.append(rec)
        events.append(rec)

    # 单独再看一次页面报错文字（切完一圈后）
    body2 = page.evaluate("document.body.innerText")
    onscreen2 = [ln for ln in body2.splitlines() if any(k in ln for k in ("失败", "错误", "没法", "不支持", "载入"))]
    cib = page.evaluate("window.__cib || []")
    return {
        "run": name,
        "console_errors": errors,
        "console_warns": warns,
        "onscreen": sorted(set(onscreen + onscreen2)),
        "cib_calls": cib,
        "results": results,
    }


# ------------------------------------------------------------------ 判据

def connected_components(fg, w, h):
    seen = bytearray(w * h)
    comps = []
    for start in range(w * h):
        if fg[start] and not seen[start]:
            stack = [start]
            seen[start] = 1
            n = 0
            while stack:
                j = stack.pop()
                n += 1
                x = j % w
                y = j // w
                for yy in range(max(0, y - 1), min(h, y + 2)):
                    base = yy * w
                    for xx in range(max(0, x - 1), min(w, x + 2)):
                        k = base + xx
                        if fg[k] and not seen[k]:
                            seen[k] = 1
                            stack.append(k)
            comps.append(n)
    comps.sort(reverse=True)
    return comps


def analyze_alpha(path, scale=0.5):
    """对画布 alpha 通道做连通域分析。"""
    im = Image.open(path).convert("RGBA")
    a = im.getchannel("A")
    w = max(1, int(a.width * scale))
    h = max(1, int(a.height * scale))
    a2 = a.resize((w, h), Image.BILINEAR)
    vals = list(a2.point(lambda v: 255 if v >= 40 else 0).getdata())
    fg = bytearray(1 if v else 0 for v in vals)
    total = sum(fg)
    if total == 0:
        return {"canvas": f"{im.width}x{im.height}", "fg_px": 0, "fg_frac": 0.0,
                "n_sig": 0, "largest_frac": 0.0, "bbox": [0, 0, 0, 0], "bbox_fill": 0.0,
                "col_span": 0.0, "row_span": 0.0}
    comps = connected_components(fg, w, h)
    min_sig = max(4, int(0.001 * w * h))
    sig = [c for c in comps if c >= min_sig]
    xs = [i % w for i in range(w * h) if fg[i]]
    ys = [i // w for i in range(w * h) if fg[i]]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    return {
        "canvas": f"{im.width}x{im.height}",
        "fg_px": total,
        "fg_frac": round(total / (w * h), 4),
        "n_comp": len(comps),
        "n_sig": len(sig),
        "largest_frac": round(sig[0] / total, 4) if sig else 0.0,
        "top_comps": [round(c / total, 4) for c in sig[:6]],
        "bbox": [x0, y0, bw, bh],
        "bbox_fill": round(total / (bw * bh), 4),
        "col_span": round(bw / w, 4),
        "row_span": round(bh / h, 4),
    }


def verdict(m):
    """完整渲染在这批模型上恰好是单一连通域（正常/兜底全 6 套 n_comp=1）；
    破碎渲染一定散成多块。所以主判据用连通域个数，largest_frac 只作辅助。"""
    if m["fg_px"] == 0:
        return "空白/没画出来"
    if m["n_comp"] == 1:
        return "完整"
    if m["n_comp"] <= 4 and m["largest_frac"] >= 0.9:
        return "基本完整"
    if m["n_comp"] >= 8 or m["largest_frac"] < 0.5:
        return "碎（散落碎片）"
    return "可疑"


def compare_rgba(p1, p2, thr=40):
    """严格比较两张画布 RGBA：逐通道最大/平均差 + alpha 掩码 IoU。"""
    i1 = Image.open(p1).convert("RGBA")
    i2 = Image.open(p2).convert("RGBA")
    if i1.size != i2.size:
        i2 = i2.resize(i1.size)
    b1 = i1.tobytes()
    b2 = i2.tobytes()
    n = len(b1)
    acc = 0
    mx = 0
    gt2 = 0
    for x, y in zip(b1, b2):
        d = x - y if x >= y else y - x
        acc += d
        if d > mx:
            mx = d
        if d > 2:
            gt2 += 1
    a1 = b1[3::4]
    a2 = b2[3::4]
    inter = sum(1 for x, y in zip(a1, a2) if x >= thr and y >= thr)
    uni = sum(1 for x, y in zip(a1, a2) if x >= thr or y >= thr)
    npx = len(a1)
    alpha_mad = sum(abs(x - y) for x, y in zip(a1, a2)) / npx
    return {
        "size": f"{i1.width}x{i1.height}",
        "chan_max_diff": mx,
        "chan_mean_diff": round(acc / n, 6),
        "chan_gt2": gt2,
        "chan_total": n,
        "alpha_iou": round(inter / uni, 6) if uni else 1.0,
        "alpha_mad": round(alpha_mad, 4),
    }


# ------------------------------------------------------------------ 主流程

def collect_alpha_tags():
    return sorted(
        f[: -len("-alpha.png")] for f in os.listdir(SHOTS) if f.endswith("-alpha.png")
    )


def analyze_shots(report):
    """从已截好的图重算指标（--analyze 用，不碰浏览器）。"""
    report["metrics"] = {}
    for tag in collect_alpha_tags():
        m = analyze_alpha(os.path.join(SHOTS, tag + "-alpha.png"))
        m["verdict"] = verdict(m)
        report["metrics"][tag] = m
    report["diffs"] = {}
    for o in OUTFITS:
        a = os.path.join(SHOTS, f"{o}-基建-alpha.png")
        b = os.path.join(SHOTS, f"fallback-{o}-基建-alpha.png")
        if os.path.exists(a) and os.path.exists(b):
            report["diffs"][f"{o}-基建 normal-vs-fallback"] = compare_rgba(a, b)
    return report


def main():
    os.makedirs(SHOTS, exist_ok=True)
    events = []
    report = {"normal": None, "fallback": None, "broken": None, "metrics": {}, "diffs": {}}

    with sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(CDP)
        ctx = browser.contexts[0]

        # 1) 正常路径：6 套（只挂记录器，不删 resize 选项）
        pg = ctx.new_page()
        pg.add_init_script(init_script())
        report["normal"] = run(pg, "normal", [(o, g, f"{o}-{g}") for o in OUTFITS for g in GROUPS], events)
        pg.close()

        # 2) 兜底路径：两套基建
        pg = ctx.new_page()
        pg.add_init_script(init_script(strip=True))
        report["fallback"] = run(
            pg, "fallback", [(o, "基建", f"fallback-{o}-基建") for o in OUTFITS], events
        )
        pg.close()

        # 3) 破损对照（标定判据）：两套基建
        pg = ctx.new_page()
        pg.add_init_script(init_script(broken=True))
        report["broken"] = run(
            pg, "broken", [(o, "基建", f"broken-{o}-基建") for o in OUTFITS], events
        )
        pg.close()

        browser.close()

    # 指标
    analyze_shots(report)

    with open(os.path.join(SHOTS, "results.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    # 打印摘要
    print(json.dumps({
        "console_errors": {
            k: (report[k] or {}).get("console_errors") for k in ("normal", "fallback", "broken")
        },
        "onscreen": {k: (report[k] or {}).get("onscreen") for k in ("normal", "fallback", "broken")},
        "results": {k: (report[k] or {}).get("results") for k in ("normal", "fallback", "broken")},
        "cib_normal": (report["normal"] or {}).get("cib_calls"),
        "cib_fallback": (report["fallback"] or {}).get("cib_calls"),
        "cib_broken": (report["broken"] or {}).get("cib_calls"),
        "metrics": report["metrics"],
        "diffs": report["diffs"],
    }, ensure_ascii=False, indent=2))


def analyze_mode():
    """--analyze：只按已存在的截图重算 metrics/diffs，写回 results.json。"""
    path = os.path.join(SHOTS, "results.json")
    report = json.load(open(path)) if os.path.exists(path) else {}
    analyze_shots(report)
    with open(path, "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    for k, m in report["metrics"].items():
        print(f"{k:42s} n_comp={m['n_comp']:3d} largest={m['largest_frac']:.3f} -> {m['verdict']}")
    print(json.dumps(report.get("diffs", {}), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    if "--analyze" in sys.argv:
        analyze_mode()
        sys.exit(0)
    sys.exit(main())
