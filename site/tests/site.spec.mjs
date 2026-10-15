import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The site ships in its coming-soon state until the first release is published. The
// release PR removes data-release="soon" from <html>. The coming-soon tests run only
// while the attribute is there; the released tests remove it in the browser, so the
// install sections are checked before that day and run unchanged after it.
const shots = `${process.env.E2E_OUT || fileURLToPath(new URL("../../verify/site/", import.meta.url))}/shots`;
const indexHtml = readFileSync(new URL("../public/index.html", import.meta.url), "utf8");
const shipsSoon = /<html[^>]*\sdata-release="soon"/.test(indexHtml);
const releases = "https://github.com/wasimjalali/useful-voice-releases/releases/latest/download/";
const assets = {
  macScript: `${releases}install.sh`,
  dmg: `${releases}Useful-Voice-macOS.dmg`,
  winScript: `${releases}install.ps1`,
  setup: `${releases}Useful-Voice-Windows-Setup.exe`,
};
const widths = [1440, 390];
const schemes = ["light", "dark"];

async function goLive(page) {
  await page.evaluate(() => document.documentElement.removeAttribute("data-release"));
}

async function settle(page) {
  await page.evaluate(() => document.fonts.ready);
  // Scroll-driven reveals only finish once each section has been in view.
  await page.evaluate(async () => {
    for (let y = 0; y < document.body.scrollHeight; y += 400) {
      window.scrollTo({ top: y, behavior: "instant" });
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    }
    window.scrollTo({ top: 0, behavior: "instant" });
  });
  await page.waitForTimeout(1500);
}

// html and body clip sideways overflow, which would hide a too-wide element from
// scrollWidth, so measure with the clip lifted. Scroll boxes such as the install
// command keep their own overflow and don't count.
async function noSideScroll(page) {
  const overflow = await page.evaluate(() => {
    const els = [document.documentElement, document.body];
    const saved = els.map((el) => el.style.overflowX);
    for (const el of els) el.style.overflowX = "visible";
    const width = document.documentElement.scrollWidth;
    els.forEach((el, i) => { el.style.overflowX = saved[i]; });
    return width - window.innerWidth;
  });
  expect(overflow, "page is wider than the viewport").toBeLessThanOrEqual(0);
}

test("the side-scroll check catches a too-wide element", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.goto("/");
  await page.evaluate(() => {
    const wide = document.createElement("div");
    wide.style.width = "2000px";
    wide.style.height = "1px";
    document.querySelector("main").append(wide);
  });
  await expect(noSideScroll(page)).rejects.toThrow("wider than the viewport");
});

for (const width of widths) {
  for (const scheme of schemes) {
    test(`coming soon, ${width}px ${scheme}`, async ({ page }) => {
      test.skip(!shipsSoon, "released: index.html no longer ships the coming-soon state");
      await page.emulateMedia({ colorScheme: scheme, reducedMotion: "reduce" });
      await page.setViewportSize({ width, height: 900 });
      await page.goto("/");
      await settle(page);
      await expect(page.locator(".when-live:visible")).toHaveCount(0);
      await expect(page.getByText("Coming soon").first()).toBeVisible();
      await expect(page.locator('a[href*="releases/latest/download"]:visible')).toHaveCount(0);
      await noSideScroll(page);
      await page.screenshot({ path: `${shots}/soon-${width}-${scheme}.png`, fullPage: true });
    });

    test(`released, ${width}px ${scheme}`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme, reducedMotion: "reduce" });
      await page.setViewportSize({ width, height: 900 });
      await page.goto("/");
      await goLive(page);
      await settle(page);
      await expect(page.locator(".when-soon:visible")).toHaveCount(0);
      await expect(page.locator("#install")).toBeVisible();
      await noSideScroll(page);
      await page.screenshot({ path: `${shots}/live-${width}-${scheme}.png`, fullPage: true });
      await page.getByRole("tab", { name: "Windows" }).click();
      await noSideScroll(page);
      await page.locator("#install").screenshot({ path: `${shots}/live-${width}-${scheme}-windows-tab.png` });
    });

    test(`privacy, ${width}px ${scheme}`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width, height: 900 });
      const response = await page.goto("/privacy/");
      expect(response.status()).toBe(200);
      await page.evaluate(() => document.fonts.ready);
      await noSideScroll(page);
      await page.screenshot({ path: `${shots}/privacy-${width}-${scheme}.png`, fullPage: true });
    });
  }
}

test("no sideways scroll at 360px in either state, or on the other pages", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.goto("/");
  await noSideScroll(page);
  await goLive(page);
  await noSideScroll(page);
  await page.getByRole("tab", { name: "Windows" }).click();
  await noSideScroll(page);
  for (const path of ["/privacy/", "/no-such-page"]) {
    await page.goto(path);
    await noSideScroll(page);
  }
});

test("the release flip is complete", async () => {
  // Once data-release="soon" is gone, the JSON-LD must name the download.
  test.skip(shipsSoon, "still coming soon");
  expect(indexHtml).toContain(`"downloadUrl":"${assets.dmg}"`);
});

test("install links point at the release asset names", async ({ page }) => {
  await page.goto("/");
  await goLive(page);
  await expect(page.locator("#install-mac")).toHaveText(`$ curl -fsSL ${assets.macScript} | sh`);
  await expect(page.locator("#install-windows")).toHaveText(`> irm ${assets.winScript} | iex`);
  const hrefs = await page.locator('a[href*="releases/latest/download"]').evaluateAll((as) => as.map((a) => a.href));
  expect(new Set(hrefs)).toEqual(new Set([assets.dmg, assets.setup]));
  // Mac panel: DMG; Windows panel: installer; closing section: both.
  expect(hrefs.filter((h) => h === assets.dmg)).toHaveLength(2);
  expect(hrefs.filter((h) => h === assets.setup)).toHaveLength(2);
});

test("platform tabs follow the ARIA tabs keyboard pattern", async ({ page }) => {
  await page.goto("/");
  await goLive(page);
  const mac = page.getByRole("tab", { name: "Mac" });
  const windows = page.getByRole("tab", { name: "Windows" });
  const shows = async (tab) => {
    const other = tab === mac ? windows : mac;
    await expect(tab).toHaveAttribute("aria-selected", "true");
    await expect(tab).toHaveAttribute("tabindex", "0");
    await expect(other).toHaveAttribute("aria-selected", "false");
    await expect(other).toHaveAttribute("tabindex", "-1");
    await expect(page.locator(tab === mac ? "#panel-mac" : "#panel-windows")).toBeVisible();
    await expect(page.locator(tab === mac ? "#panel-windows" : "#panel-mac")).toBeHidden();
  };
  await shows(mac);
  await mac.focus();
  await page.keyboard.press("ArrowRight");
  await expect(windows).toBeFocused();
  await shows(windows);
  await page.keyboard.press("ArrowRight");
  await expect(mac).toBeFocused();
  await shows(mac);
  await page.keyboard.press("ArrowLeft");
  await expect(windows).toBeFocused();
  await shows(windows);
  await page.keyboard.press("Home");
  await expect(mac).toBeFocused();
  await shows(mac);
  await page.keyboard.press("End");
  await expect(windows).toBeFocused();
  await shows(windows);
  await mac.click();
  await shows(mac);
});

const visitors = [
  { name: "Windows", platform: "Win32", uaPlatform: "Windows", tab: "Windows" },
  { name: "Mac", platform: "MacIntel", uaPlatform: "macOS", tab: "Mac" },
  { name: "Linux", platform: "Linux x86_64", uaPlatform: "Linux", tab: "Mac" },
  { name: "Darwin", platform: "darwin", uaPlatform: "", tab: "Mac" },
];
for (const visitor of visitors) {
  test(`a ${visitor.name} visitor starts on the ${visitor.tab} tab`, async ({ page }) => {
    await page.addInitScript(({ platform, uaPlatform }) => {
      Object.defineProperty(navigator, "platform", { get: () => platform });
      Object.defineProperty(navigator, "userAgentData", { get: () => (uaPlatform ? { platform: uaPlatform } : undefined) });
    }, visitor);
    await page.goto("/");
    await goLive(page);
    await expect(page.getByRole("tab", { name: visitor.tab })).toHaveAttribute("aria-selected", "true");
  });
}

test("Copy puts the exact command on the clipboard", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  await goLive(page);
  await page.getByRole("button", { name: "Copy the Mac install command" }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`curl -fsSL ${assets.macScript} | sh`);
  await expect(page.locator("#copy-status")).toHaveText("Install command copied.");
  await page.getByRole("tab", { name: "Windows" }).click();
  const winButton = page.getByRole("button", { name: "Copy the Windows install command" });
  await winButton.click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`irm ${assets.winScript} | iex`);
  // A second copy within the reset delay keeps its own label and message for the full delay.
  await page.waitForTimeout(1200);
  await expect(winButton).toHaveText("Copied");
  await expect(page.locator("#copy-status")).toHaveText("Install command copied.");
  await expect(winButton).toHaveText("Copy", { timeout: 3000 });
  await expect(page.locator("#copy-status")).toHaveText("");
});

test("when the clipboard refuses, the command is selected instead", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "clipboard", { get: () => ({ writeText: () => Promise.reject(new Error("denied")) }) });
  });
  await page.goto("/");
  await goLive(page);
  const button = page.getByRole("button", { name: "Copy the Mac install command" });
  await button.click();
  await expect(button).toHaveText("Selected");
  await expect(page.locator("#copy-status")).toHaveText("Couldn't copy. The command is selected: copy it with your keyboard.");
  expect(await page.evaluate(() => window.getSelection().toString().replace(/^\$ /, ""))).toBe(`curl -fsSL ${assets.macScript} | sh`);
});

test("every local link and asset resolves, and the server behaves like Cloudflare", async ({ page, request }) => {
  const seen = new Set();
  for (const path of ["/", "/privacy/", "/404.html"]) {
    await page.goto(path);
    const refs = await page.evaluate(() =>
      [...document.querySelectorAll("[href], [src]")].map((el) => el.getAttribute("href") ?? el.getAttribute("src")),
    );
    for (const ref of refs) {
      if (!ref || /^(https?:|mailto:|#)/.test(ref)) continue;
      const url = new URL(ref, `http://localhost${path}`).pathname;
      if (seen.has(url)) continue;
      seen.add(url);
      expect((await request.get(url)).status(), url).toBe(200);
    }
  }
  for (const file of ["/robots.txt", "/sitemap.xml", "/og.png", "/favicon.svg", "/fonts/OFL.txt"]) {
    expect((await request.get(file)).status(), file).toBe(200);
  }
  const redirect = await request.get("/privacy", { maxRedirects: 0 });
  expect(redirect.status()).toBe(307);
  expect(redirect.headers().location).toBe("/privacy/");
  expect((await request.get("/_headers")).status()).toBe(404);
  // A browser lands on the 404 page itself, not a download.
  const missing = await page.goto("/no-such-page");
  expect(missing.status()).toBe(404);
  await expect(page.getByRole("heading", { name: "This page isn't here." })).toBeVisible();
});

test("no page loads third-party resources, sets cookies or ships analytics", async ({ page, context }) => {
  const external = [];
  page.on("request", (r) => { if (!r.url().startsWith("http://localhost")) external.push(r.url()); });
  for (const path of ["/", "/privacy/", "/no-such-page"]) {
    await page.goto(path);
    await settle(page);
  }
  expect(external).toEqual([]);
  expect(await context.cookies()).toEqual([]);
  for (const file of ["index.html", "privacy/index.html", "404.html"]) {
    const html = readFileSync(new URL(`../public/${file}`, import.meta.url), "utf8");
    expect(html, file).not.toMatch(/<script[^>]*\ssrc=|posthog|gtag\(|googletagmanager|plausible\.io/i);
  }
});
