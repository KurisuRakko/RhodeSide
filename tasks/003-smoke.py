#!/usr/bin/env python3
"""任务 003：Rhodeside 设置页 + 桌宠页浏览器冒烟测试（只测不改）。

连到临时无头 Chrome 9335（swiftshader），新开 context：
  - settings.html：界面元素、二级联动、开关、忽略名单、toast、深浅色截图
  - pet.html：scale / hit / pause / fps 四类消息
结果写 tasks/003-shots/results.json 与 console-*.json。
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import re
import sys
import time
import traceback

from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = "/home/rakko/Collection/SpineStage"
SHOTS = os.path.join(ROOT, "tasks/003-shots")
os.makedirs(SHOTS, exist_ok=True)

CDP = "http://127.0.0.1:9335"
SETTINGS_URL = "http://127.0.0.1:8066/settings.html"
PET_URL = "http://127.0.0.1:8066/pet.html?model=%E8%8D%92%E8%8A%9C%E6%8B%89%E6%99%AE%E5%85%B0%E5%BE%B7&group=%E5%9F%BA%E5%BB%BA&height=200"

RESULTS: list[dict] = []


def rec(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append({"name": name, "ok": bool(ok), "detail": str(detail)})
    print(("PASS  " if ok else "FAIL  ") + name + (("  — " + str(detail)) if detail else ""), flush=True)


def note(name: str, detail: str) -> None:
    RESULTS.append({"name": name, "ok": None, "detail": str(detail)})
    print("NOTE  " + name + "  — " + str(detail), flush=True)


def wait_until(fn, timeout=8.0, interval=0.12, desc=""):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
            last = v
        except Exception as exc:  # noqa: BLE001
            last = repr(exc)
        time.sleep(interval)
    raise AssertionError(f"超时等待 {desc or fn}（最后={last!r}）")


def attach_console(page, bucket: list) -> None:
    def on_console(msg):
        item = {"type": msg.type, "text": msg.text}
        try:
            vals = []
            for a in msg.args:
                try:
                    vals.append(a.json_value())
                except Exception:  # noqa: BLE001
                    vals.append("<unserializable>")
            item["args"] = vals
        except Exception:  # noqa: BLE001
            item["args"] = None
        bucket.append(item)

    page.on("console", on_console)
    page.on("pageerror", lambda e: bucket.append({"type": "pageerror", "text": str(e)}))


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "")).strip()


def text_of(loc, n: int = 0) -> str:
    try:
        return norm(loc.nth(n).inner_text())
    except Exception:  # noqa: BLE001
        return "<none>"


def selected_of(group) -> str:
    """分段选择当前选中项的文字（aria-checked / data-checked 两种都看）。"""
    for sel in ('[role=radio][aria-checked="true"]', '[aria-checked="true"]', '[data-checked]'):
        el = group.locator(sel)
        if el.count():
            return norm(el.first.inner_text())
    return "<none>"


def switch_state(sw) -> str:
    for attr in ("aria-checked", "data-checked"):
        v = sw.get_attribute(attr)
        if v is not None:
            return v
    return "<none>"


def snap_png(page) -> bytes:
    url = page.evaluate("document.getElementById('pet').toDataURL('image/png')")
    return base64.b64decode(url.split(",", 1)[1])


def md5(b: bytes) -> str:
    return hashlib.md5(b).hexdigest()


# --- Base UI Select 辅助：只认「当前可见的弹层」，并在开/关之间同步，避免被 inert 遮罩挡住

VISIBLE_OPTIONS = "[role=listbox]:visible [role=option]"
VISIBLE_LISTBOX = "[role=listbox]:visible"


def open_select(page, trigger) -> None:
    trigger.click()
    wait_until(lambda: page.locator(VISIBLE_LISTBOX).count() > 0, desc="下拉弹出")


def visible_options(page) -> list:
    return [norm(x) for x in page.locator(VISIBLE_OPTIONS).all_inner_texts()]


def choose_option(page, text: str) -> None:
    loc = page.locator(VISIBLE_OPTIONS).filter(has_text=text)
    wait_until(lambda: loc.count() > 0, desc=f"选项 {text}")
    loc.first.click()
    wait_until(lambda: page.locator(VISIBLE_LISTBOX).count() == 0, desc="下拉关闭")


def close_select(page) -> None:
    if page.locator(VISIBLE_LISTBOX).count():
        page.keyboard.press("Escape")
        try:
            wait_until(lambda: page.locator(VISIBLE_LISTBOX).count() == 0, timeout=3, desc="下拉关闭")
        except AssertionError:
            page.mouse.click(5, 5)
            wait_until(lambda: page.locator(VISIBLE_LISTBOX).count() == 0, timeout=3, desc="下拉关闭(点空白)")


# --------------------------------------------------------------------------- 设置页

def run_settings(browser, out: dict) -> None:
    print("\n================ 设置页 ================", flush=True)
    ctx = browser.new_context(viewport={"width": 800, "height": 900}, device_scale_factor=1)
    page = ctx.new_page()
    logs: list = []
    attach_console(page, logs)

    page.goto(SETTINGS_URL, wait_until="load")
    page.wait_for_timeout(3000)
    page.screenshot(path=os.path.join(SHOTS, "settings-1.png"), full_page=True)
    note("settings-1.png", "已保存（full_page）")

    body_text = page.inner_text("body")
    out["body_text_after_3s"] = body_text
    out["loading_stuck"] = "正在连 Rhodeside" in body_text

    rec("设置页：标题 Rhodeside", text_of(page.locator("h1.rs-title")) == "Rhodeside", text_of(page.locator("h1.rs-title")))
    badges = [norm(x) for x in page.locator(".rs-badge").all_inner_texts()]
    rec("设置页：有「浏览器预览」徽标", any("浏览器预览" in b for b in badges), f"badges={badges}")

    sections = [norm(x) for x in page.locator(".rs-section__title").all_inner_texts()]
    have = {s: any(s in x for x in sections) for s in ("桌宠", "通用", "模型", "调试")}
    rec("设置页：桌宠/通用/模型/调试 四个分区", all(have.values()), f"sections={sections}")

    # 第 1 只卡片
    wait_until(lambda: page.locator(".rs-card__title").count() >= 1, desc="第 1 只卡片")
    t1 = text_of(page.locator(".rs-card__title"))
    rec("设置页：第 1 只 · 荒芜拉普兰德", t1 == "第 1 只 · 荒芜拉普兰德", t1)

    # 模型列表 N 套（等 "…" 变数字）
    def model_metas():
        rows = page.locator(".rs-item")
        d = {}
        for i in range(rows.count()):
            nm = text_of(rows.nth(i).locator(".rs-item__name"))
            mt = text_of(rows.nth(i).locator(".rs-item__meta"))
            if nm:
                d[nm] = mt
        return d

    try:
        wait_until(
            lambda: ("荒芜拉普兰德" in model_metas() and "test-puppet" in model_metas()
                     and "…" not in model_metas().get("荒芜拉普兰德", "…")
                     and "…" not in model_metas().get("test-puppet", "…")),
            timeout=25, desc="模型列表 N 套",
        )
        metas = model_metas()
        rec("设置页：模型列表有 荒芜拉普兰德 与 test-puppet", "荒芜拉普兰德" in metas and "test-puppet" in metas, str(metas))
        m1 = re.search(r"(\d+)\s*套", metas.get("荒芜拉普兰德", ""))
        m2 = re.search(r"(\d+)\s*套", metas.get("test-puppet", ""))
        rec("设置页：两个模型都显示 N 套（数字，不是 …）", bool(m1) and bool(m2),
            f"荒芜拉普兰德={metas.get('荒芜拉普兰德')} / test-puppet={metas.get('test-puppet')}")
        out["model_metas"] = metas
    except AssertionError as exc:
        rec("设置页：模型列表 N 套", False, str(exc))
        out["model_metas"] = model_metas()

    # --- 添加一只
    page.locator("button:has-text('添加一只')").first.click()
    wait_until(lambda: page.locator(".rs-card").count() == 2, desc="第 2 只卡片")
    t2 = text_of(page.locator(".rs-card__title"), 1)
    rec("设置页：添加一只 → 第 2 只出现", t2.startswith("第 2 只"), t2)

    card2 = page.locator(".rs-card").nth(1)
    # 大小 → 大
    g_size = card2.locator("[role=radiogroup][aria-label='大小']")
    before_size = selected_of(g_size)
    g_size.get_by_role("radio", name="大", exact=True).click()
    page.wait_for_timeout(300)
    after_size = selected_of(g_size)
    rec("设置页：第 2 只「大小」点成 大，选中态翻转", after_size == "大" and after_size != before_size,
        f"{before_size} → {after_size}")

    # 步速 → 快
    g_stride = card2.locator("[role=radiogroup][aria-label='步速']")
    before_stride = selected_of(g_stride)
    g_stride.get_by_role("radio", name="快", exact=True).click()
    page.wait_for_timeout(300)
    after_stride = selected_of(g_stride)
    rec("设置页：第 2 只「步速」点成 快，选中态翻转", after_stride == "快" and after_stride != before_stride,
        f"{before_stride} → {after_stride}")

    # --- 收起两次
    btn = card2.locator("button:has-text('收起')").first
    btn.click()
    page.wait_for_timeout(300)
    txt1 = norm(btn.inner_text())
    rec("设置页：点「收起」→ 变成「再点一下收起」", "再点一下收起" in txt1, txt1)
    btn.click()
    wait_until(lambda: page.locator(".rs-card").count() == 1, desc="第 2 只消失")
    rec("设置页：再点一下 → 第 2 只消失", page.locator(".rs-card").count() == 1,
        f"剩余卡片={page.locator('.rs-card').count()}")

    # --- 模型下拉 → test-puppet
    card1 = page.locator(".rs-card").first
    open_select(page, card1.locator("button[aria-label='模型']"))
    opts = visible_options(page)
    out["model_options"] = opts
    choose_option(page, "test-puppet")
    wait_until(lambda: text_of(page.locator(".rs-card__title")) == "第 1 只 · test-puppet", timeout=8,
               desc="标题变 test-puppet")
    rec("设置页：模型切 test-puppet → 卡片标题变", text_of(page.locator(".rs-card__title")) == "第 1 只 · test-puppet",
        text_of(page.locator(".rs-card__title")))

    # 模型组下拉
    try:
        wait_until(lambda: card1.locator("button[aria-label='模型组']").count() > 0, timeout=10,
                   desc="模型组下拉出现")
        open_select(page, card1.locator("button[aria-label='模型组']"))
        gopts = visible_options(page)
        out["testpuppet_group_options"] = gopts
        close_select(page)
        rec("设置页：切 test-puppet 后出现「模型组」且选项是它的组", len(gopts) > 0,
            f"选项={gopts}")
    except AssertionError as exc:
        rec("设置页：切 test-puppet 后出现「模型组」", False, str(exc))

    # --- 切回荒芜拉普兰德 → 时装两个
    open_select(page, card1.locator("button[aria-label='模型']"))
    choose_option(page, "荒芜拉普兰德（内置）")
    wait_until(lambda: text_of(page.locator(".rs-card__title")) == "第 1 只 · 荒芜拉普兰德", timeout=8,
               desc="标题切回荒芜拉普兰德")
    rec("设置页：切回荒芜拉普兰德 → 标题恢复", text_of(page.locator(".rs-card__title")) == "第 1 只 · 荒芜拉普兰德",
        text_of(page.locator(".rs-card__title")))
    try:
        wait_until(lambda: card1.locator("button[aria-label='时装']").count() > 0, timeout=10, desc="时装下拉出现")
        open_select(page, card1.locator("button[aria-label='时装']"))
        fopts = visible_options(page)
        out["outfit_options"] = fopts
        close_select(page)
        rec("设置页：切回后「时装」下拉出现两个时装", len(fopts) == 2, f"选项={fopts}")
    except AssertionError as exc:
        rec("设置页：切回后「时装」下拉出现两个时装", False, str(exc))

    # --- 通用三个开关
    sec = page.locator(".rs-section").filter(has_text="通用").first
    switches = sec.locator("[role=switch]")
    n = switches.count()
    flips = []
    for i in range(min(n, 3)):
        sw = switches.nth(i)
        b = switch_state(sw)
        sw.click()
        page.wait_for_timeout(250)
        a = switch_state(sw)
        flips.append((b, a, b != a))
    rec("设置页：通用里三个开关各点一次状态翻转", n >= 3 and all(f[2] for f in flips[:3]),
        f"共 {n} 个开关，翻转={flips}")

    # --- 忽略名单
    inp = sec.locator("input[placeholder*='程序名']").first
    inp.fill("TestApp")
    sec.locator("button:has-text('加上')").first.click()
    chip = sec.locator(".rs-chip", has_text="TestApp")
    try:
        wait_until(lambda: chip.count() > 0, desc="TestApp chip 出现")
        rec("设置页：忽略名单加 TestApp → 出现 chip", chip.count() > 0,
            f"chips={[norm(x) for x in sec.locator('.rs-chip').all_inner_texts()]}")
        restore_seen = sec.locator("button:has-text('恢复默认')").count() > 0
        rec("设置页：改动后出现「恢复默认」按钮", restore_seen, f"可见={restore_seen}")
        sec.locator(".rs-chip__x[aria-label='去掉 TestApp']").click()
        wait_until(lambda: chip.count() == 0, desc="chip 消失")
        rec("设置页：点 chip 的 ✕ → chip 消失", chip.count() == 0,
            f"chips={[norm(x) for x in sec.locator('.rs-chip').all_inner_texts()]}")
        # 再改一次，用「恢复默认」恢复
        inp.fill("TestApp")
        sec.locator("button:has-text('加上')").first.click()
        wait_until(lambda: chip.count() > 0, desc="TestApp 再次出现")
        rb = sec.locator("button:has-text('恢复默认')")
        if rb.count():
            rb.first.click()
            wait_until(lambda: chip.count() == 0, desc="恢复默认后 chip 消失")
            chips_after = [norm(x) for x in sec.locator(".rs-chip").all_inner_texts()]
            rec("设置页：点「恢复默认」→ 回到默认列表", chip.count() == 0 and len(chips_after) == 3,
                f"chips={chips_after}")
        else:
            rec("设置页：点「恢复默认」", False, "按钮未出现")
    except AssertionError as exc:
        rec("设置页：忽略名单 chip 流程", False, str(exc))

    # --- 导入模型 → toast
    page.locator("button:has-text('导入模型')").first.click()
    try:
        wait_until(lambda: page.locator(".rk-snackbar").count() > 0, timeout=5, desc="toast")
        toast_txt = norm(page.locator(".rk-snackbar").first.inner_text())
        rec("设置页：点「导入模型…」→ 出 toast（浏览器预览没有这个功能）",
            "浏览器预览" in toast_txt and "没有这个功能" in toast_txt, toast_txt)
        out["toast_text"] = toast_txt
    except AssertionError as exc:
        rec("设置页：点「导入模型…」→ 出 toast", False, str(exc))
        out["toast_text"] = None

    page.screenshot(path=os.path.join(SHOTS, "settings-2.png"), full_page=True)
    note("settings-2.png", "已保存（full_page）")

    errs = [l for l in logs if l["type"] in ("error",)]
    warns = [l for l in logs if l["type"] == "warning"]
    pgerrs = [l for l in logs if l["type"] == "pageerror"]
    out["console_error"] = errs
    out["console_warn"] = warns
    out["pageerror"] = pgerrs
    rec("设置页：无 console error", len(errs) == 0, f"{len(errs)} 条：{[e['text'] for e in errs]}")
    rec("设置页：无 pageerror", len(pgerrs) == 0, f"{len(pgerrs)} 条：{[e['text'] for e in pgerrs]}")
    note("设置页 console warn", f"{len(warns)} 条：" + str([w["text"][:120] for w in warns[:8]]))

    with open(os.path.join(SHOTS, "console-settings.json"), "w", encoding="utf-8") as f:
        json.dump(logs, f, ensure_ascii=False, indent=2)

    # --- 深色模式
    try:
        page2 = ctx.new_page()
        dlogs: list = []
        attach_console(page2, dlogs)
        page2.emulate_media(color_scheme="dark")
        page2.goto(SETTINGS_URL, wait_until="load")
        page2.wait_for_timeout(3000)
        page2.screenshot(path=os.path.join(SHOTS, "settings-dark.png"), full_page=True)
        diag = page2.evaluate(
            """() => {
              const parse = (s) => { const m = s.match(/rgba?\\(([^)]+)\\)/); if(!m) return null;
                const p = m[1].split(',').map(x=>parseFloat(x)); return {r:p[0],g:p[1],b:p[2],a:p.length>3?p[3]:1}; };
              const lum = (c) => { const f=(v)=>{v/=255; return v<=0.03928? v/12.92 : Math.pow((v+0.055)/1.055,2.4);};
                return 0.2126*f(c.r)+0.7152*f(c.g)+0.0722*f(c.b); };
              const bgOf = (el) => { let n=el; while(n && n!==document.documentElement){
                  const c=parse(getComputedStyle(n).backgroundColor); if(c && c.a>0.05) return c; n=n.parentElement;}
                return parse(getComputedStyle(document.body).backgroundColor) || {r:255,g:255,b:255,a:1}; };
              const ratio = (a,b) => { const l1=lum(a), l2=lum(b); const hi=Math.max(l1,l2), lo=Math.min(l1,l2);
                return (hi+0.05)/(lo+0.05); };
              const sels = ['.rs-title','.rs-sub','.rs-badge','.rs-section__title','.rs-card__title','.rs-card__status',
                '.rs-label','.rs-label__hint','.rs-item__name','.rs-item__meta','.rs-chip','.rs-hint','.rs-toggle__hint'];
              const items = {};
              for (const s of sels) { const el=document.querySelector(s); if(!el) continue;
                const cs=getComputedStyle(el); const fg=parse(cs.color); const bg=bgOf(el);
                items[s] = { color: cs.color, bg: `rgba(${bg.r},${bg.g},${bg.b},${bg.a})`,
                  contrast: Math.round(ratio(fg,bg)*100)/100 }; }
              return { theme: document.documentElement.getAttribute('data-theme'),
                bodyBg: getComputedStyle(document.body).backgroundColor, items };
            }"""
        )
        out["dark"] = diag
        low = {k: v for k, v in diag["items"].items() if v["contrast"] < 3.0}
        rec("设置页：深色模式 data-theme=dark", diag["theme"] == "dark", str(diag["theme"]))
        rec("设置页：深色模式没有对比度过低的文字（<3:1）", len(low) == 0, f"低对比={low}")
        d_errs = [l for l in dlogs if l["type"] == "error"]
        rec("设置页：深色模式无 console error", len(d_errs) == 0, f"{[e['text'] for e in d_errs]}")
        note("settings-dark.png", "已保存（full_page）")
    except Exception as exc:  # noqa: BLE001
        rec("设置页：深色模式", False, repr(exc))

    page.close()
    ctx.close()


# --------------------------------------------------------------------------- 桌宠页

def run_pet(browser, out: dict) -> None:
    print("\n================ 桌宠页 ================", flush=True)
    ctx = browser.new_context(viewport={"width": 400, "height": 400}, device_scale_factor=1)
    page = ctx.new_page()
    logs: list = []
    attach_console(page, logs)

    page.goto(PET_URL, wait_until="load")
    page.wait_for_timeout(6000)
    try:
        wait_until(lambda: page.evaluate("window.__pet && window.__pet.layout"), timeout=15, desc="__pet.layout")
    except AssertionError as exc:
        rec("桌宠页：6 秒内拿到 layout", False, str(exc))

    geom = page.evaluate(
        """() => { const c = document.getElementById('pet');
             return { cw: c.width, ch: c.height, clientW: c.clientWidth, clientH: c.clientHeight,
                      dpr: window.devicePixelRatio, layout: window.__pet.layout }; }"""
    )
    out["pet_geom_initial"] = geom
    layout0 = geom["layout"]
    rec("桌宠页：拿到 __pet.layout", layout0 is not None, str(layout0))
    note("桌宠页几何", f"canvas={geom['cw']}x{geom['ch']} client={geom['clientW']}x{geom['clientH']} dpr={geom['dpr']}")

    # --- scale
    page.evaluate("window.__pet.receive({type:'scale', height: 120})")
    page.wait_for_timeout(1000)
    layout1 = page.evaluate("window.__pet.layout")
    out["pet_layout_before"] = layout0
    out["pet_layout_after_scale"] = layout1
    rec("桌宠页：scale 120 → layout 变小", layout1 and layout0 and layout1["h"] < layout0["h"] and layout1["w"] <= layout0["w"],
        f"{layout0} → {layout1}")
    layout_msgs = [l for l in logs if isinstance(l.get("args"), list) and len(l["args"]) > 1
                   and isinstance(l["args"][1], dict) and l["args"][1].get("type") == "layout"]
    out["layout_msgs"] = layout_msgs
    rec("桌宠页：console 里有 type:'layout' 消息", len(layout_msgs) > 0,
        f"{len(layout_msgs)} 条，最后一条={layout_msgs[-1]['args'][1] if layout_msgs else None}")

    # --- hit：从画布找一个四周 3*dpr 内都不透明的点
    png = snap_png(page)
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    W, H = img.size
    px_ = img.load()
    dpr = geom["dpr"]
    r = max(1, round(3 * dpr))
    margin = r + 1
    pick = None
    for y in range(margin, H - margin):
        for x in range(margin, W - margin):
            if px_[x, y][3] > 200:
                ok = True
                for dy in range(-r, r + 1):
                    for dx in range(-r, r + 1):
                        if px_[x + dx, y + dy][3] <= 24:
                            ok = False
                            break
                    if not ok:
                        break
                if ok:
                    pick = (x, y)
                    break
        if pick:
            break
    out["canvas_size"] = [W, H]
    if not pick:
        rec("桌宠页：画布上找到实心不透明像素", False, "没找到")
    else:
        xc, yc = pick
        # 画布像素坐标：原点左上、y 向下；消息坐标：CSS px、原点左下、y 向上
        css_x = (xc + 0.5) / dpr
        css_y = (H - 1 - yc + 0.5) / dpr
        out["hit_pick"] = {"canvas_px": [xc, yc], "msg": [css_x, css_y],
                           "conversion": "css_x=(xc+0.5)/dpr ; css_y=(H-1-yc+0.5)/dpr"}
        n0 = len(logs)
        page.evaluate(f"window.__pet.receive({{type:'hit', id:1, x:{css_x}, y:{css_y}}})")
        page.wait_for_timeout(400)
        hit_msgs = [l for l in logs[n0:] if isinstance(l.get("args"), list) and len(l["args"]) > 1
                    and isinstance(l["args"][1], dict) and l["args"][1].get("type") == "hit"]
        inside = hit_msgs[-1]["args"][1].get("inside") if hit_msgs else None
        rec("桌宠页：hit 不透明点 → inside:true", inside is True,
            f"画布像素 {pick} → 消息 ({css_x:.2f},{css_y:.2f})，回 {hit_msgs[-1]['args'][1] if hit_msgs else None}")

        # 四角透明点：画布左上角 (0,0) 对应左下角附近的点
        corner = px_[0, 0]
        css_x0 = 0.5 / dpr
        css_y0 = (H - 1 - 0 + 0.5) / dpr
        n1 = len(logs)
        page.evaluate(f"window.__pet.receive({{type:'hit', id:1, x:{css_x0}, y:{css_y0}}})")
        page.wait_for_timeout(400)
        hit_msgs2 = [l for l in logs[n1:] if isinstance(l.get("args"), list) and len(l["args"]) > 1
                     and isinstance(l["args"][1], dict) and l["args"][1].get("type") == "hit"]
        inside2 = hit_msgs2[-1]["args"][1].get("inside") if hit_msgs2 else None
        rec("桌宠页：hit 透明角点 → inside:false", inside2 is False,
            f"画布四角 alpha={corner[3]}，消息 ({css_x0:.2f},{css_y0:.2f})，回 {hit_msgs2[-1]['args'][1] if hit_msgs2 else None}")

    # --- pause
    page.evaluate("window.__pet.receive({type:'pause', paused:true})")
    page.wait_for_timeout(1000)
    a = snap_png(page)
    page.wait_for_timeout(500)
    b = snap_png(page)
    same_paused = a == b
    out["pause_same"] = same_paused
    rec("桌宠页：pause:true 两次画布完全相同", same_paused, f"len={len(a)}/{len(b)} md5={md5(a)[:10]}/{md5(b)[:10]}")

    page.evaluate("window.__pet.receive({type:'pause', paused:false})")
    page.wait_for_timeout(1000)
    c = snap_png(page)
    page.wait_for_timeout(500)
    d = snap_png(page)
    diff_px = None
    if c == d:
        rec("桌宠页：pause:false 两次画布不同（小人在动）", False, "两次完全相同")
    else:
        im1 = Image.open(io.BytesIO(c)).convert("RGBA")
        im2 = Image.open(io.BytesIO(d)).convert("RGBA")
        p1, p2 = im1.load(), im2.load()
        diff_px = sum(1 for yy in range(im1.height) for xx in range(im1.width) if p1[xx, yy] != p2[xx, yy])
        rec("桌宠页：pause:false 两次画布不同（小人在动）", diff_px > 0, f"不同像素={diff_px}")
    out["unpause_diff_px"] = diff_px

    # --- fps
    def ten_frames(tag, interval=0.1):
        hashes = []
        for _ in range(10):
            hashes.append(md5(snap_png(page)))
            time.sleep(interval)
        return hashes, len(set(hashes))

    page.evaluate("window.__pet.receive({type:'fps', value:0})")
    page.wait_for_timeout(300)
    h_unlimited, d_unlimited = ten_frames("unlimited")
    out["fps_unlimited_distinct"] = d_unlimited

    page.evaluate("window.__pet.receive({type:'fps', value:5})")
    page.wait_for_timeout(300)
    h5, d5 = ten_frames("fps5")
    out["fps5_distinct"] = d5
    rec("桌宠页：fps=5 → 10 次取样画面种类明显少于 10", d5 < 10 and d5 <= 7,
        f"fps=5 不同画面={d5}/10（对照不限帧={d_unlimited}/10）")
    rec("桌宠页：不限帧对照（10 次取样接近 10 种）", d_unlimited >= 8, f"不同画面={d_unlimited}/10")

    page.evaluate("window.__pet.receive({type:'fps', value:0})")
    page.wait_for_timeout(300)
    after = page.evaluate("window.__pet.layout")
    rec("桌宠页：fps=0 恢复（页面仍活着）", after is not None, str(after))

    errs = [l for l in logs if l["type"] == "error"]
    pgerrs = [l for l in logs if l["type"] == "pageerror"]
    out["pet_console_error"] = errs
    out["pet_pageerror"] = pgerrs
    rec("桌宠页：无 console error", len(errs) == 0, f"{[e['text'] for e in errs]}")
    rec("桌宠页：无 pageerror", len(pgerrs) == 0, f"{[e['text'] for e in pgerrs]}")

    with open(os.path.join(SHOTS, "console-pet.json"), "w", encoding="utf-8") as f:
        json.dump(logs, f, ensure_ascii=False, indent=2)

    page.close()
    ctx.close()


def main() -> int:
    with sync_playwright() as pw:
        browser = pw.chromium.connect_over_cdp(CDP)
        print(f"connected: {CDP}  contexts={len(browser.contexts)}", flush=True)
        out: dict = {}
        out["cdp"] = CDP

        run_settings(browser, out)
        run_pet(browser, out)

        with open(os.path.join(SHOTS, "results.json"), "w", encoding="utf-8") as f:
            json.dump({"results": RESULTS, "data": out}, f, ensure_ascii=False, indent=2)

        fails = [r for r in RESULTS if r["ok"] is False]
        passes = [r for r in RESULTS if r["ok"] is True]
        print("\n================ 汇总 ================", flush=True)
        print(f"PASS={len(passes)}  FAIL={len(fails)}  NOTE={len(RESULTS)-len(passes)-len(fails)}", flush=True)
        for r in fails:
            print("  FAIL: " + r["name"] + " — " + r["detail"], flush=True)
        return 1 if fails else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        traceback.print_exc()
        print("HARNESS ERROR: " + repr(exc), flush=True)
        try:
            with open(os.path.join(SHOTS, "results.json"), "w", encoding="utf-8") as f:
                json.dump({"results": RESULTS, "harness_error": repr(exc)}, f, ensure_ascii=False, indent=2)
        except Exception:  # noqa: BLE001
            pass
        sys.exit(2)
