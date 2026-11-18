// Run against a disposable NewsDrop server with the seeded public directory.
// Creates an account and an RSS connection. No feed is registered.
// node tests/browser/account-journey.cjs http://localhost:<port>
// Requires playwright-core and Chromium; CHROMIUM_PATH can select an installed browser.
const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const {chromium} = require("playwright-core");

async function exercise() {
    const address = process.argv[2];
    assert.ok(address, "Pass the URL of a disposable NewsDrop server.");
    const origin = new URL(address).origin;
    const browser = await chromium.launch({executablePath: process.env.CHROMIUM_PATH});
    try {
        const page = await browser.newPage({viewport: {width: 1366, height: 768}});
        const pageErrors = [];
        page.on("pageerror", error => pageErrors.push(error.message));
        await page.route("**/*", route => {
            if (new URL(route.request().url()).origin === origin) return route.continue();
            return route.abort();
        });

        await page.goto(origin + "/discover");
        const preview = page.locator(".channel-disclosure").first();
        await preview.locator("summary").click();
        await preview.getByRole("link", {name: /Open channel/}).click();
        const channel = new URL(page.url()).pathname;
        await page.getByRole("link", {name: "Sign in to follow", exact: true}).click();
        const destination = new URL(new URL(page.url()).searchParams.get("next"), origin);
        assert.equal(destination.origin, origin);
        assert.equal(destination.pathname, channel);

        await page.getByRole("button", {name: /Need an account/}).click();
        assert.equal(await page.getByLabel("Username").evaluate(input => input === document.activeElement), true);
        await page.getByText("Use at least 12 characters.").waitFor();
        const name = "browser-" + randomUUID();
        const email = name + "@example.invalid";
        const password = randomUUID();
        await page.getByLabel("Username").fill(name);
        await page.getByLabel("Email").fill(email);
        await page.getByLabel("Password", {exact: true}).fill(password);
        await page.getByRole("button", {name: "Register", exact: true}).click();
        await page.waitForURL(destination.href);
        const logout = page.getByRole("button", {name: "Log out", exact: true});
        await logout.waitFor();

        await page.getByRole("link", {name: "My Sources", exact: true}).click();
        await page.getByRole("heading", {name: "Your sources"}).waitFor();
        assert.match(await page.title(), /My Sources/);
        const add = page.getByRole("button", {name: "+ Add source", exact: true});
        await add.click();
        await page.getByRole("button", {name: "Add connection", exact: true}).click();
        const locator = page.getByLabel("Feed URL or X account");
        await locator.waitFor();
        assert.equal(await locator.evaluate(input => input === document.activeElement), true);
        await locator.fill("invalid-source");
        await page.getByRole("button", {name: "Follow source", exact: true}).click();
        await page.locator(".ps-add-source").getByRole("alert").waitFor();
        await page.getByRole("button", {name: "Cancel", exact: true}).click();
        await add.click();
        await locator.waitFor();

        await page.setViewportSize({width: 390, height: 844});
        await logout.click();
        await page.getByLabel("Email").waitFor();
        await page.getByRole("navigation").getByRole("link", {name: "Log in", exact: true}).waitFor();
        await page.goto(origin + "/login?next=" + encodeURIComponent("https://example.invalid/"));
        await page.getByLabel("Email").fill(email);
        await page.getByLabel("Password", {exact: true}).fill(randomUUID());
        await page.getByRole("button", {name: "Log in", exact: true}).click();
        await page.getByRole("alert").filter({hasText: "Invalid email or password"}).waitFor();
        await page.getByLabel("Password", {exact: true}).fill(password);
        await page.getByRole("button", {name: "Log in", exact: true}).click();
        await page.waitForURL(origin + "/");
        await logout.waitFor();
        assert.deepEqual(pageErrors, []);
    } finally {
        await browser.close();
    }
}
exercise().then(() => console.log("Account and source setup checks passed.")).catch(error => {
    console.error(error);
    process.exitCode = 1;
});
