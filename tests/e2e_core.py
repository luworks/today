"""Core gestures and secondary views: swipe rows, long-press menu, calendar drag, ring, search, sheets, dark mode.
Run: BASE=http://localhost:8787 python3 tests/e2e_core.py   (needs: pip install playwright && playwright install chromium)"""
import asyncio, os, pathlib
from playwright.async_api import async_playwright
BASE = os.environ.get('BASE', 'http://127.0.0.1:8787')
S = str(pathlib.Path(__file__).parent / 'shots') + '/'; pathlib.Path(S).mkdir(exist_ok=True)

async def touch(cdp, typ, x=0, y=0):
    await cdp.send('Input.dispatchTouchEvent', {'type': typ, 'touchPoints': [] if typ == 'touchEnd' else [{'x': x, 'y': y}]})

def step(n): print('--', n, flush=True)

ROW = "(sel)=>{const e=[...document.querySelectorAll(sel)].find(x=>{const r=x.getBoundingClientRect();return r.top>140&&r.bottom<700});const r=e.getBoundingClientRect();return {x:r.left,y:r.top+r.height/2,w:r.width,id:e.dataset.id}}"

async def main():
    fails = 0
    async with async_playwright() as p:
        b = await p.chromium.launch()
        c = await b.new_context(viewport={'width': 393, 'height': 852}, device_scale_factor=2, is_mobile=True, has_touch=True)
        pg = await c.new_page(); errs = []; pg.set_default_timeout(5000)
        pg.on('console', lambda m: errs.append(m.text) if m.type in ('error', 'warning') else None)
        pg.on('pageerror', lambda e: errs.append('PAGEERR ' + str(e)))
        await pg.goto(BASE + '/'); await pg.wait_for_timeout(400)
        cdp = await c.new_cdp_session(pg)
        task = lambda i: pg.evaluate(f"todayV8.data.tasks.find(t=>t.id=='{i}')")
        def check(ok, label):
            nonlocal fails
            print(('PASS ' if ok else 'FAIL ') + label)
            if not ok: fails += 1
        try:
            step('tasks: swipe right completes')
            await pg.evaluate("todayV8.go('tasks')"); await pg.wait_for_timeout(300)
            r = await pg.evaluate(ROW, '.sw-fg:not(.done)')
            await touch(cdp, 'touchStart', r['x'] + 60, r['y'])
            for i in range(1, 12): await touch(cdp, 'touchMove', r['x'] + 60 + i * 16, r['y'] + 1); await pg.wait_for_timeout(16)
            await touch(cdp, 'touchEnd'); await pg.wait_for_timeout(500)
            check((await task(r['id']))['done'], 'swipe right → done')
            step('swipe left reveals actions')
            r = await pg.evaluate(ROW, '.sw-fg:not(.done)')
            await touch(cdp, 'touchStart', r['x'] + r['w'] - 40, r['y'])
            for i in range(1, 12): await touch(cdp, 'touchMove', r['x'] + r['w'] - 40 - i * 15, r['y']); await pg.wait_for_timeout(16)
            await touch(cdp, 'touchEnd'); await pg.wait_for_timeout(400)
            check(await pg.evaluate("document.querySelectorAll('.sw-fg.open').length") == 1, 'swipe left → actions open')
            await pg.click(f'.sw-bg.r [data-act=t-tomorrow][data-id="{r["id"]}"]'); await pg.wait_for_timeout(300)
            check((await task(r['id']))['date'] == '2026-10-13', 'Tomorrow action sets planned day')
            step('long press menu')
            r = await pg.evaluate(ROW, '.sw-fg:not(.done)')
            await touch(cdp, 'touchStart', r['x'] + 120, r['y']); await pg.wait_for_timeout(700); await touch(cdp, 'touchEnd'); await pg.wait_for_timeout(400)
            check(await pg.evaluate("!!document.querySelector('.menu.show')"), 'long press → menu')
            await pg.click('.menu .cancel'); await pg.wait_for_timeout(400)
            step('calendar: week and month only')
            await pg.evaluate("todayV8.go('calendar')"); await pg.wait_for_timeout(300)
            check(await pg.evaluate("[...document.querySelectorAll('.seg button')].map(b=>b.textContent).join()") == 'Week,Month', 'calendar has Week and Month, no Day')
            check(await pg.evaluate("document.querySelectorAll('.wk-row').length") == 7, 'week view shows 7 days')
            await pg.click('[data-act=cal-mode][data-v=month]'); await pg.wait_for_timeout(200)
            check(await pg.evaluate("document.querySelectorAll('.md').length") == 35, 'month view shows October 2026 as 5 weeks')
            await pg.click('.md.today'); await pg.wait_for_timeout(300)
            check(await pg.evaluate("document.querySelector('.navbar .nb-title, #navbar .nb-title')?.textContent.includes('Monday')"), 'tapping a day opens it in Today')
            step('alarms + ring')
            await pg.evaluate("todayV8.go('alarms')"); await pg.wait_for_timeout(200)
            await pg.evaluate("todayV8.A['al-preview']({dataset:{id:'a1'}})"); await pg.wait_for_timeout(200); await pg.screenshot(path=S + 'core_ring.png')
            await pg.click('[data-act=ring-stop]'); await pg.wait_for_timeout(300)
            check(not await pg.evaluate("document.querySelector('#ring-root').innerHTML"), 'ring screen closes')
            step('search')
            await pg.click('.navbar [data-act=search]'); await pg.wait_for_timeout(400); await pg.fill('#sq', 'demo'); await pg.wait_for_timeout(150)
            check(await pg.evaluate("document.querySelectorAll('.sheet .sr').length") > 0, 'search finds results')
            await pg.keyboard.press('Escape'); await pg.wait_for_timeout(400)
            step('task sheet detents')
            await pg.evaluate("todayV8.go('tasks')"); await pg.wait_for_timeout(200)
            await pg.click('.sw-fg .rt >> nth=0'); await pg.wait_for_timeout(450)
            g = await pg.evaluate("(()=>{const r=document.querySelector('.grab').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+8}})()")
            await pg.mouse.move(g['x'], g['y']); await pg.mouse.down(); await pg.mouse.move(g['x'], g['y'] + 300, steps=10); await pg.mouse.up(); await pg.wait_for_timeout(400)
            check('translateY(' in (await pg.evaluate("document.querySelector('.sheet')?.style.transform") or ''), 'sheet snaps to medium')
            g = await pg.evaluate("(()=>{const r=document.querySelector('.grab').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+8}})()")
            await pg.mouse.move(g['x'], g['y']); await pg.mouse.down(); await pg.mouse.move(g['x'], g['y'] + 600, steps=10); await pg.mouse.up(); await pg.wait_for_timeout(450)
            check(await pg.evaluate("!document.querySelector('.sheet')"), 'sheet dismisses on pull-down')
            step('dark + large text')
            await pg.evaluate("todayV8.go('today');document.documentElement.dataset.theme='dark';document.documentElement.style.setProperty('--fs',1.25)"); await pg.wait_for_timeout(200)
            await pg.screenshot(path=S + 'core_dark_large.png')
        except Exception as e:
            fails += 1; print('FAIL', str(e)[:300]); await pg.screenshot(path=S + 'core_fail.png')
        check(not errs, 'no console errors ' + (str(errs) if errs else ''))
        await b.close()
    raise SystemExit(1 if fails else 0)

asyncio.run(main())
