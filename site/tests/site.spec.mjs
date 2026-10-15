import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// The site ships in its coming-soon state until the first release is published. The
// release PR removes data-release="soon" from <html>; the live tests below remove it
// in the browser so the install sections are checked before that day.
const shots = `${process.env.E2E_OUT || new URL("../../verify/site/", import.meta.url).pathname}/shots`;
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
      window.scrollTo(0, y);
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    }
    window.scrollTo(0, 0);
  });
  await page.waitForTimeout(1200);
}

async function noSideScroll(page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "page scrolls sideways").toBeLessThanOrEqual(0);
}

for (const width of widths) {
  for (const scheme of schemes) {
    test(`coming soon, ${width}px ${scheme}`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme, reducedMotion: "reduce" });
      await page.setViewportSize({ width, height: 900 });
      await page.goto("/");
      await settle(page);
      await expect(page.locator("html")).toHaveAttribute("data-release", "soon");
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

test("no sideways scroll at 360px in either state", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.goto("/");
  await noSideScroll(page);
  await goLive(page);
  await noSideScroll(page);
  await page.getByRole("tab", { name: "Windows" }).click();
  await noSideScroll(page);
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

test("platform tabs switch by click and arrow keys", async ({ page }) => {
  await page.goto("/");
  await goLive(page);
  const mac = page.getByRole("tab", { name: "Mac" });
  const windows = page.getByRole("tab", { name: "Windows" });
  await expect(mac).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#panel-mac")).toBeVisible();
  await expect(page.locator("#panel-windows")).toBeHidden();
  await mac.focus();
  await page.keyboard.press("ArrowRight");
  await expect(windows).toBeFocused();
  await expect(windows).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#panel-windows")).toBeVisible();
  await expect(page.locator("#panel-mac")).toBeHidden();
  await page.keyboard.press("ArrowRight");
  await expect(mac).toBeFocused();
  await expect(page.locator("#panel-mac")).toBeVisible();
  await windows.click();
  await expect(page.locator("#panel-windows")).toBeVisible();
});

test.describe("a Windows visitor", () => {
  test.use({ userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36" });
  test("starts on the Windows tab", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "platform", { get: () => "Win32" });
      Object.defineProperty(navigator, "userAgentData", { get: () => ({ platform: "Windows" }) });
    });
    await page.goto("/");
    await goLive(page);
    await expect(page.getByRole("tab", { name: "Windows" })).toHaveAttribute("aria-selected", "true");
  });
});

test("a Mac visitor starts on the Mac tab", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "platform", { get: () => "MacIntel" });
    Object.defineProperty(navigator, "userAgentData", { get: () => ({ platform: "macOS" }) });
  });
  await page.goto("/");
  await goLive(page);
  await expect(page.getByRole("tab", { name: "Mac" })).toHaveAttribute("aria-selected", "true");
});

test("Copy puts the exact command on the clipboard", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  await goLive(page);
  await page.getByRole("button", { name: "Copy the Mac install command" }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`curl -fsSL ${assets.macScript} | sh`);
  await expect(page.locator("#copy-status")).toHaveText("Install command copied.");
  await page.getByRole("tab", { name: "Windows" }).click();
  await page.getByRole("button", { name: "Copy the Windows install command" }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`irm ${assets.winScript} | iex`);
});

test("every local link and asset resolves, and an unknown path gets the 404 page", async ({ page, request }) => {
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
  for (const file of ["/robots.txt", "/sitemap.xml", "/og.png", "/favicon.svg"]) {
    expect((await request.get(file)).status(), file).toBe(200);
  }
  const missing = await request.get("/no-such-page");
  expect(missing.status()).toBe(404);
  expect(await missing.text()).toContain("This page isn't here.");
});

test("the page ships no third-party scripts, cookies or analytics", async ({ page, context }) => {
  const external = [];
  page.on("request", (r) => { if (!r.url().startsWith("http://localhost")) external.push(r.url()); });
  await page.goto("/");
  await settle(page);
  expect(external).toEqual([]);
  expect(await context.cookies()).toEqual([]);
  const html = readFileSync(new URL("../public/index.html", import.meta.url), "utf8");
  expect(html).not.toMatch(/<script[^>]*\ssrc=|posthog|gtag\(|googletagmanager|plausible\.io/i);
});
