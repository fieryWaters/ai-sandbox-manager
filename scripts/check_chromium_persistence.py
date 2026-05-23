import os
from glob import glob

from playwright.sync_api import sync_playwright


profile = os.environ.get("CHROMIUM_PROFILE", "/home/agent/.config/chromium")
chrome = sorted(glob("/opt/ms-playwright/chromium-*/chrome-linux/chrome"))[-1]
args = ["--no-sandbox", "--disable-dev-shm-usage", "--disable-background-networking"]
origin = "http://youart-persist.test/"
body = "<!doctype html><title>persist</title><body>persist</body>"


def launch():
    pw = sync_playwright().start()
    ctx = pw.chromium.launch_persistent_context(
        profile,
        executable_path=chrome,
        headless=True,
        args=args,
    )
    page = ctx.new_page()
    page.route(
        "**/*",
        lambda route: route.fulfill(status=200, content_type="text/html", body=body),
    )
    page.goto(origin)
    return pw, ctx, page


pw, ctx, page = launch()
page.evaluate("localStorage.setItem('youart-smoke', 'persist-ok')")
ctx.close()
pw.stop()

pw, ctx, page = launch()
print(page.evaluate("localStorage.getItem('youart-smoke')"))
ctx.close()
pw.stop()
