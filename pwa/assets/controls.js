(() => {
    // The Tauri webview keeps its existing native notification behavior.
    if (window.__TAURI__ || window.__TAURI_INTERNALS__ || !window.isSecureContext) return;

    let installPrompt;
    const controls = () => document.querySelector("newsstream-pwa");
    window.addEventListener("beforeinstallprompt", (event) => {
        event.preventDefault();
        installPrompt = event;
        controls()?.updateInstall();
    });
    window.addEventListener("appinstalled", () => {
        installPrompt = null;
        controls()?.updateInstall();
    });

    const ios = /iPad|iPhone|iPod/.test(navigator.userAgent)
        || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const standalone = () => matchMedia("(display-mode: standalone)").matches
        || navigator.standalone === true;
    let worker;
    if ("serviceWorker" in navigator) {
        worker = navigator.serviceWorker
            .register("/newsstream-sw.js", { scope: "/", updateViaCache: "none" })
            .then(() => navigator.serviceWorker.ready)
            .catch(() => null);
    }

    const sessionEvent = "ns-session";
    async function clearNotices() {
        try {
            const registration = await worker;
            for (const notice of await registration?.getNotifications() || []) {
                if (notice.tag.startsWith("newsstream-push-")) notice.close();
            }
        } catch { /* Session ownership is enforced on the server. */ }
    }
    window.addEventListener(sessionEvent, clearNotices);

    async function request(route, body, method = "POST") {
        const response = await fetch("/api/me/web-push/" + route, {
            method, credentials: "same-origin", cache: "no-store",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
        });
        if (response.ok) return response.status === 204 ? undefined : response.json();
        const error = new Error();
        error.status = response.status;
        throw error;
    }

    function applicationKey(encoded) {
        const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/");
        return Uint8Array.from(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
            (character) => character.charCodeAt(0));
    }

    class NewsstreamPwa extends HTMLElement {
        connectedCallback() {
            this.innerHTML = `
                <button type="button" class="ps-quiet" data-install hidden>Install NewsDrop</button>
                <span data-install-help></span>
                <button type="button" class="ps-quiet" data-push hidden>Enable Web Push</button>
                <span data-push-help role="status"></span>`;
            this.installButton = this.querySelector("[data-install]");
            this.installHelp = this.querySelector("[data-install-help]");
            this.pushButton = this.querySelector("[data-push]");
            this.pushHelp = this.querySelector("[data-push-help]");
            this.installButton.onclick = () => this.install();
            this.pushButton.onclick = () => this.toggle();
            this.updateInstall();
            this.check = () => this.refresh();
            window.addEventListener("focus", this.check);
            window.addEventListener(sessionEvent, this.check);
            this.timer = setInterval(this.check, 30000);
            this.refresh();
        }

        disconnectedCallback() {
            window.removeEventListener("focus", this.check);
            window.removeEventListener(sessionEvent, this.check);
            clearInterval(this.timer);
        }

        updateInstall() {
            this.installButton.hidden = standalone() || !installPrompt;
            this.installHelp.textContent = standalone() ? "" : ios
                ? "On iPhone or iPad, open Safari’s Share menu and choose Add to Home Screen."
                : installPrompt ? "" : "Install NewsDrop from your browser menu when available.";
        }

        async install() {
            const prompt = installPrompt;
            installPrompt = null;
            try {
                if (prompt) await prompt.prompt();
            } catch { /* The browser menu remains available. */ }
            this.updateInstall();
        }

        async refresh() {
            if (this.busy || this.refreshing) return;
            if (ios && !standalone()) {
                this.pushHelp.textContent = "Open NewsDrop from the Home Screen to enable Web Push.";
                return;
            }
            if (!worker || !("PushManager" in window) || !("Notification" in window)) {
                this.pushHelp.textContent = "Web Push is unavailable in this browser.";
                return;
            }
            this.refreshing = true;
            this.pushButton.disabled = true;
            try {
                this.registration = await worker;
                if (!this.registration) throw new Error();
                this.subscription = await this.registration.pushManager.getSubscription();
                const config = await request("status", { endpoint: this.subscription?.endpoint });
                if (!this.isConnected) return;
                if (this.config && this.config.binding !== config.binding) clearNotices();
                this.config = config;
                if (config.active && Notification.permission !== "granted") {
                    await this.disable();
                }
                this.toggleAttribute("data-push-active", config.active);
                this.pushButton.hidden = !config.publicKey;
                this.pushButton.textContent = config.active ? "Disable Web Push" : "Enable Web Push";
                this.pushHelp.textContent = !config.publicKey ? "Web Push is unavailable on this server."
                    : config.active ? "This device receives alerts from your selected sources."
                    : "Receive personal alerts even when NewsDrop is closed.";
            } catch (error) {
                this.removeAttribute("data-push-active");
                this.pushButton.hidden = true;
                this.pushHelp.textContent = error.status === 401
                    ? "Sign in to enable Web Push." : "Could not check Web Push. Try reloading.";
                if (error.status === 401) clearNotices();
            } finally {
                this.refreshing = false;
                this.pushButton.disabled = false;
            }
        }

        async disable() {
            const { binding } = this.config;
            await request("subscription", { endpoint: this.subscription.endpoint, binding }, "DELETE");
            this.config.active = false;
            await this.subscription.unsubscribe();
            this.subscription = null;
            await clearNotices();
        }

        async toggle() {
            if (this.busy || this.refreshing) return;
            this.busy = true;
            this.pushButton.disabled = true;
            const { publicKey, binding, active } = this.config;
            let message = "";
            let created;
            try {
                if (active) {
                    await this.disable();
                } else {
                    // This is the only permission request, directly in the click handler.
                    if (await Notification.requestPermission() !== "granted") {
                        message = "Allow notifications in your browser or device settings, then try again.";
                        return;
                    }
                    if (this.subscription) await this.subscription.unsubscribe();
                    created = await this.registration.pushManager.subscribe({
                        userVisibleOnly: true,
                        applicationServerKey: applicationKey(publicKey),
                    });
                    await request("subscription", { ...created.toJSON(), binding }, "PUT");
                }
            } catch (error) {
                if (created) await created.unsubscribe().catch(() => {});
                message = error.status === 409 || error.status === 401
                    ? "The session or browser subscription changed. Sign in and try again."
                    : "Could not change Web Push on this device.";
            } finally {
                this.busy = false;
                await this.refresh();
                if (message) this.pushHelp.textContent = message;
            }
        }
    }

    customElements.define("newsstream-pwa", NewsstreamPwa);

    // The personal feed arrives asynchronously after session verification.
    let articleObserver;
    function focusArticle() {
        articleObserver?.disconnect();
        const item = /^#(personal-item-\d+)$/.exec(location.hash)?.[1];
        if (!item || location.pathname !== "/sources") return;
        const scroll = () => {
            const article = document.getElementById(item);
            if (!article) return false;
            article.scrollIntoView({ block: "center" });
            return true;
        };
        if (!scroll()) {
            const observer = new MutationObserver(() => {
                if (scroll()) observer.disconnect();
            });
            articleObserver = observer;
            observer.observe(document.body, { subtree: true, childList: true });
            setTimeout(() => observer.disconnect(), 30000);
        }
    }
    focusArticle();
    window.addEventListener("hashchange", focusArticle);
})();
