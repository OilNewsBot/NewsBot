const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.join(__dirname, "..");
const assets = path.join(root, "pwa", "assets");
const worker = fs.readFileSync(path.join(assets, "sw.js"), "utf8");
const ticket = "a".repeat(32);

function harness(fetch) {
    const listeners = new Map();
    const notices = [];
    const navigations = [];
    const client = {
        url: "https://example.test/sources",
        navigate: async (url) => { navigations.push(url); return client; },
        focus: async () => {},
    };
    const self = {
        location: { origin: "https://example.test" },
        clients: { matchAll: async () => [client], claim: async () => {} },
        registration: { showNotification: async (title, options) => notices.push({ title, options }) },
        addEventListener: (name, handler) => listeners.set(name, handler),
    };
    vm.runInNewContext(worker, { self, fetch, URL, Response });
    function event(name, args) {
        let pending;
        listeners.get(name)({
            ...args,
            waitUntil: (promise) => { pending = promise; },
            respondWith: (promise) => { pending = promise; },
        });
        return pending;
    }
    return { event, notices, navigations };
}

test("manifest declares the root scope and actual install icon sizes", () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(assets, "manifest.webmanifest")));
    assert.equal(manifest.display, "standalone");
    assert.equal(manifest.scope, "/");
    assert.equal(manifest.start_url, "/sources");
    assert.equal(manifest.icons.length, 2);
    for (const icon of manifest.icons) {
        const file = icon.src.endsWith("192.png") ? path.join(assets, "icon-192.png")
            : path.join(root, "desktop", "src-tauri", "icons", "icon.png");
        const image = fs.readFileSync(file);
        assert.equal(image.subarray(1, 4).toString("ascii"), "PNG");
        assert.equal(icon.sizes, `${image.readUInt32BE(16)}x${image.readUInt32BE(20)}`);
    }
});

test("worker fetches navigations without caching and leaves API and SSE alone", async () => {
    const { event } = harness(async (request, options) => {
        assert.equal(options.cache, "no-store");
        throw new Error("offline");
    });
    assert.equal(event("fetch", { request: { mode: "cors", url: "https://example.test/api/me/feed" } }), undefined);
    assert.equal(event("fetch", { request: { mode: "cors", url: "https://example.test/api/me/stream" } }), undefined);
    const page = await event("fetch", {
        request: { mode: "navigate", url: "https://example.test/trading" },
    });
    assert.equal(page.status, 503);
    const html = await page.text();
    assert.match(html, /NewsStream is offline/);
    assert.equal(new URL(html.match(/href="([^"]*)"/)[1], "https://example.test/trading").pathname, "/trading");
});

test("worker shows a generic notice and rechecks ownership when clicked", async () => {
    let signedIn = true;
    const { event, notices, navigations } = harness(async (url, options) => {
        assert.equal(url, "/api/me/web-push/destination");
        assert.equal(options.credentials, "same-origin");
        assert.equal(options.cache, "no-store");
        assert.equal(JSON.parse(options.body).ticket, ticket);
        return signedIn ? Response.json({ itemId: 42 }) : new Response(null, { status: 401 });
    });
    await event("activate", {});
    await event("push", { data: { json: () => ({ ticket }) } });
    assert.equal(notices.length, 1);
    assert.equal(notices[0].title, "NewsStream");
    assert.equal(notices[0].options.body, "New post from one of your selected sources.");
    const notification = { close: () => {}, data: notices[0].options.data };
    await event("notificationclick", { notification });
    assert.equal(navigations[0], "https://example.test/sources#personal-item-42");
    signedIn = false;
    await event("push", { data: { json: () => ({ ticket }) } });
    assert.equal(notices.length, 1);
    await event("notificationclick", { notification });
    assert.equal(navigations[1], "https://example.test/sources");
});
