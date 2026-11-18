// Use the browser's normal waiting/activation lifecycle for updates.
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (event) => {
    if (event.request.mode !== "navigate"
        || new URL(event.request.url).origin !== self.location.origin) return;
    // App pages, authenticated API responses and SSE are never put in CacheStorage.
    event.respondWith(fetch(event.request, { cache: "no-store" }).catch(() =>
        new Response(`<!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>NewsDrop is offline</title><h1>NewsDrop is offline</h1>
        <p>Reconnect to open your news and sources.</p><a href="">Try again</a></html>`,
        { status: 503, headers: { "Content-Type": "text/html; charset=utf-8" } })
    ));
});

async function destination(ticket) {
    if (typeof ticket !== "string" || !/^[A-Za-z0-9_-]{32}$/.test(ticket)) return null;
    try {
        const response = await fetch("/api/me/web-push/destination", {
            method: "POST", credentials: "same-origin", cache: "no-store",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ ticket }),
        });
        if (response.ok) {
            const { itemId } = await response.json();
            if (Number.isSafeInteger(itemId) && itemId > 0) return "/sources#personal-item-" + itemId;
        }
    } catch { /* With no current session or connection there is no private destination. */ }
    return null;
}

self.addEventListener("push", (event) => {
    let ticket;
    try { ticket = event.data?.json()?.ticket; } catch { return; }
    event.waitUntil((async () => {
        if (!await destination(ticket)) return;
        await self.registration.showNotification("NewsDrop", {
            body: "New post from one of your selected sources.",
            icon: "/pwa/icon-192.png",
            tag: "newsstream-push-" + ticket,
            data: { ticket },
        });
    })());
});

self.addEventListener("notificationclick", (event) => {
    event.notification.close();
    event.waitUntil((async () => {
        const path = await destination(event.notification.data?.ticket) || "/sources";
        const url = new URL(path, self.location.origin).href;
        const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
        const current = windows.find((client) => {
            const location = new URL(client.url);
            return location.origin === self.location.origin && location.pathname === "/sources";
        });
        if (current) {
            const navigated = await current.navigate(url).catch(() => null);
            if (navigated) return navigated.focus();
        }
        return self.clients.openWindow(url);
    })());
});
