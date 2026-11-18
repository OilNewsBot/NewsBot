// Exercise the built Jac client offline. Requires playwright-core and Chromium.
// CHROMIUM_PATH selects a browser and NEWSSTREAM_HTML can select a separate build.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright-core");

const html = fs.readFileSync(process.env.NEWSSTREAM_HTML ||
    path.resolve(__dirname, "../../.jac/client/web/dist/index.html"), "utf8");
const report = (id, story_id, section) => ({
    id, story_id, section, title: "Report " + id,
    published: "2026-11-" + String(id).padStart(2, "0") + "T12:00:00Z"
});
const shared = report(4, 10, "tech");
const channels = [
    {slug: "desk", name: "First desk", source_type: "rss", category: "tech", tags: ["tech"],
        headlines: [report(5, 10, "tech"), shared, report(3, 11, "energy"), report(1, 13, "tech")]},
    {slug: "wire", name: "Second desk", source_type: "community", category: "energy", tags: ["energy"],
        headlines: [report(6, 12, "energy"), shared]}
].map(ch => ({clicks: 0, recommendations: 0, description: "", ...ch}));

async function check() {
    const browser = await chromium.launch({executablePath: process.env.CHROMIUM_PATH});
    try {
        const page = await browser.newPage({viewport: {width: 1440, height: 900}});
        const errors = [];
        page.on("pageerror", err => errors.push(err.message));
        await page.route("**/*", route => {
            const url = new URL(route.request().url());
            if (route.request().resourceType() === "document") {
                return route.fulfill({contentType: "text/html", body: html});
            }
            if (url.pathname === "/api/channels") return route.fulfill({json: {channels}});
            return route.fulfill({status: 401, json: {detail: "Signed out"}});
        });
        await page.goto("http://newsstream.test/discover");
        const panel = page.getByRole("complementary", {name: "Reading insights"});
        const toggle = page.getByRole("button", {name: "Insights", exact: true});
        await panel.waitFor();
        assert.equal(await page.title(), "Discover · NewsDrop");
        assert.equal(await page.getByRole("link", {name: "NewsDrop home"}).locator("img").getAttribute("src"),
            "/brand/drop.svg");
        assert.deepEqual(await panel.locator("dd").allTextContents(), ["2", "4"]);
        assert.deepEqual(await panel.locator(".insight-stories a").allTextContents(),
            ["Report 6", "Report 5", "Report 3"]);
        assert.equal(await panel.locator(".insight-stories a").first().getAttribute("href"), "/stories/12");

        await page.getByLabel("Category", {exact: true}).selectOption("tech");
        // The fourth report enters the sector-specific preview and a syndicated copy counts once.
        assert.deepEqual(await panel.locator("dd").allTextContents(), ["2", "3"]);
        assert.deepEqual(await panel.locator(".insight-stories a").allTextContents(), ["Report 5", "Report 1"]);
        await page.getByRole("button", {name: "Trending", exact: true}).click();
        assert.deepEqual(await panel.locator("dd").allTextContents(), ["0", "0"]);
        assert.equal(await panel.locator(".source-mix li").count(), 0);

        assert.match(await page.locator(".directory-heading [role=status]").innerText(), /0 channels of 2/);

        await page.getByRole("button", {name: "All channels", exact: true}).click();
        const search = page.getByRole("searchbox", {name: "Search channels"});
        const sort = page.getByLabel("Sort by", {exact: true});
        const firstCard = page.locator('.channel-disclosure[data-channel="desk"]');
        await search.fill("FIRST");
        await sort.selectOption("category");
        assert.equal(await page.locator(".channel-disclosure").count(), 1);
        assert.match(await page.locator(".directory-heading [role=status]").innerText(), /1 channel of 2/);
        await firstCard.locator(":scope > summary").click();
        await firstCard.getByRole("link", {name: "Open channel"}).click();
        await page.waitForURL("**/channels/desk");
        await page.goBack();
        await firstCard.locator(".channel-actions a").waitFor();
        assert.equal(await search.inputValue(), "FIRST");
        assert.equal(await sort.inputValue(), "category");
        assert.equal(await page.getByLabel("Category", {exact: true}).inputValue(), "tech");

        await page.getByRole("button", {name: "New channels", exact: true}).click();
        await firstCard.getByRole("link", {name: "Open channel"}).click();
        await page.goBack();
        await firstCard.locator(".channel-actions a").waitFor();
        assert.equal(await page.getByRole("button", {name: "New channels"}).getAttribute("aria-pressed"), "true");
        await search.fill("unmatched channel");
        assert.equal(await page.locator(".channel-disclosure").count(), 0);
        assert.equal(await page.getByText("No channels match your search or filters.").isVisible(), true);

        await toggle.focus();
        await page.keyboard.press("Enter");
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        await page.reload();
        await toggle.waitFor();
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        await page.evaluate(() => localStorage.clear());
        await page.setViewportSize({width: 375, height: 760});
        await page.reload();
        await toggle.waitFor();
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        const heading = page.getByRole("heading", {name: "Discover", exact: true});
        const headingTop = () => heading.evaluate(node => node.getBoundingClientRect().top + scrollY);
        const before = await headingTop();
        await toggle.click();
        const drawer = page.getByRole("dialog", {name: "Reading insights"});
        await drawer.waitFor();
        assert.equal(await headingTop(), before);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await page.keyboard.press("Escape");
        await drawer.waitFor({state: "hidden"});
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        assert.equal(await toggle.evaluate(node => node === document.activeElement), true);
        await toggle.click();
        await drawer.getByRole("button", {name: "Close insights"}).click();
        await drawer.waitFor({state: "hidden"});
        assert.deepEqual(errors, []);
    } finally {
        await browser.close();
    }
}
check().then(() => console.log("Forum insights browser checks passed.")).catch(err => {
    console.error(err);
    process.exitCode = 1;
});
