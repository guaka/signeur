import QRCode from "qrcode";
import {
    SimplePool,
    finalizeEvent,
    generateSecretKey,
    getPublicKey,
    nip19,
    nip44,
    verifyEvent
} from "nostr-tools";

export const DEFAULT_RELAYS = [
    "wss://relay.damus.io",
    "wss://nos.lol"
];

const NIP46_KIND = 24_133;
const CONNECTION_TIMEOUT_MS = 8_000;
const APPROVAL_TIMEOUT_MS = 5 * 60_000;
const PUBLIC_KEY_TIMEOUT_MS = 2 * 60_000;

export function buildNostrConnectURI({
    clientPubkey,
    relays,
    secret,
    name = "Signstr NIP-46 tester",
    url = "https://guaka.github.io/signstr/",
    permissions = ["get_public_key", "ping"]
}) {
    if (!/^[0-9a-f]{64}$/.test(clientPubkey)) {
        throw new Error("The temporary client public key is invalid.");
    }
    if (!Array.isArray(relays) || relays.length === 0) {
        throw new Error("At least one relay is required.");
    }
    if (!secret) {
        throw new Error("A pairing secret is required.");
    }

    const params = new URLSearchParams();
    for (const relay of relays) params.append("relay", relay);
    params.set("secret", secret);
    params.set("perms", permissions.join(","));
    params.set("name", name);
    params.set("url", url);
    return `nostrconnect://${clientPubkey}?${params.toString()}`;
}

export async function connectRequestID(clientPubkey, secret, subtle = globalThis.crypto?.subtle) {
    if (!subtle) throw new Error("Secure hashing is unavailable in this browser.");
    const material = new TextEncoder().encode(`${clientPubkey}:${secret}`);
    const digest = new Uint8Array(await subtle.digest("SHA-256", material));
    return "connect-" + [...digest.slice(0, 16)]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
}

export function parseNIP46Response(plaintext) {
    let response;
    try {
        response = JSON.parse(plaintext);
    } catch {
        throw new Error("Signstr returned a response that was not valid JSON.");
    }
    if (!response || typeof response !== "object" || typeof response.id !== "string") {
        throw new Error("Signstr returned a malformed NIP-46 response.");
    }
    if (response.error != null) {
        const validString = typeof response.error === "string";
        const validObject = typeof response.error === "object"
            && Number.isInteger(response.error.code)
            && typeof response.error.message === "string";
        if (!validString && !validObject) {
            throw new Error("Signstr returned a malformed error response.");
        }
    }
    if (response.result != null && typeof response.result !== "string") {
        throw new Error("Signstr returned a malformed result.");
    }
    return response;
}

function errorMessage(responseError) {
    return typeof responseError === "string" ? responseError : responseError?.message;
}

export function validateConnectResponse(response, expectedID, expectedSecret) {
    if (response.id !== expectedID) return false;
    if (response.error) throw new Error(errorMessage(response.error));
    if (response.result !== expectedSecret) {
        throw new Error("The signer response did not contain the expected pairing secret.");
    }
    return true;
}

export function validateUserPubkey(value) {
    if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
        throw new Error("Signstr returned an invalid user public key.");
    }
    return value;
}

export function publicKeyFromSecret(secretKey) {
    return getPublicKey(secretKey);
}

export function encryptNIP46Payload(plaintext, senderSecret, recipientPubkey) {
    const conversationKey = nip44.getConversationKey(senderSecret, recipientPubkey);
    return nip44.encrypt(plaintext, conversationKey);
}

export function decryptNIP46Payload(ciphertext, receiverSecret, senderPubkey) {
    const conversationKey = nip44.getConversationKey(receiverSecret, senderPubkey);
    return nip44.decrypt(ciphertext, conversationKey);
}

export function createNIP46RequestEvent({
    clientSecret,
    signerPubkey,
    id,
    method,
    params = [],
    createdAt = Math.floor(Date.now() / 1000)
}) {
    const content = encryptNIP46Payload(
        JSON.stringify({ id, method, params }),
        clientSecret,
        signerPubkey
    );
    return finalizeEvent({
        kind: NIP46_KIND,
        created_at: createdAt,
        tags: [["p", signerPubkey]],
        content
    }, clientSecret);
}

export function friendlyError(error) {
    const message = error instanceof Error ? error.message : String(error || "Unknown error");
    if (message === "userRejected") return "The request was declined in Signstr.";
    if (message.includes("expected pairing secret")) {
        return "The response could not be authenticated. Reset the test and create a fresh pairing code.";
    }
    if (message.includes("timed out")) {
        return "No response arrived in time. Keep this page open, check Signstr is online, then try again.";
    }
    if (message.includes("relay") || message.includes("Relay")) {
        return "The page could not reach a Nostr relay. Check your connection or try again in a moment.";
    }
    return message;
}

function randomHex(bytes = 16) {
    const value = new Uint8Array(bytes);
    globalThis.crypto.getRandomValues(value);
    return [...value].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function timeoutAfter(milliseconds, message) {
    return new Promise((_, reject) => {
        const timer = setTimeout(() => reject(new Error(message)), milliseconds);
        timer.unref?.();
    });
}

class NIP46BrowserSession {
    constructor(elements) {
        this.elements = elements;
        this.pool = null;
        this.subscription = null;
        this.timer = null;
        this.deadline = null;
        this.clientSecret = null;
        this.clientPubkey = null;
        this.signerPubkey = null;
        this.connectID = null;
        this.publicKeyRequestID = null;
        this.pairingSecret = null;
        this.relays = [];
        this.uri = null;
        this.phase = "idle";
    }

    async start() {
        this.reset();
        if (!globalThis.crypto?.getRandomValues || !globalThis.crypto?.subtle || !globalThis.WebSocket) {
            this.fail(new Error("This test needs a modern secure browser with WebSocket support."));
            return;
        }

        this.setBusy(true, "Connecting to relays…");
        this.setPhase("relay");
        try {
            this.clientSecret = generateSecretKey();
            this.clientPubkey = getPublicKey(this.clientSecret);
            this.pairingSecret = randomHex(16);
            this.connectID = await connectRequestID(this.clientPubkey, this.pairingSecret);
            this.pool = new SimplePool({ enableReconnect: true });
            this.relays = await this.connectRelays(DEFAULT_RELAYS);
            this.subscribe();

            const pageURL = `${location.origin}${location.pathname}`;
            this.uri = buildNostrConnectURI({
                clientPubkey: this.clientPubkey,
                relays: this.relays,
                secret: this.pairingSecret,
                url: pageURL
            });
            await QRCode.toCanvas(this.elements.qr, this.uri, {
                width: 272,
                margin: 2,
                color: { dark: "#111117", light: "#ffffff" },
                errorCorrectionLevel: "M"
            });
            this.elements.rawLink.href = this.uri;
            this.elements.openLink.href = this.uri;
            this.elements.linkValue.value = this.uri;
            this.elements.clientKey.textContent = this.clientPubkey.slice(0, 12) + "…";
            this.elements.relayList.textContent = this.relays
                .map((relay) => relay.replace("wss://", ""))
                .join(" · ");
            this.elements.panel.hidden = false;
            this.elements.intro.hidden = true;
            this.setBusy(false);
            this.setPhase("approval");
            this.startCountdown(APPROVAL_TIMEOUT_MS, "Pairing timed out.");
        } catch (error) {
            this.fail(error);
        }
    }

    async connectRelays(relays) {
        const attempts = relays.map(async (relay) => {
            await Promise.race([
                this.pool.ensureRelay(relay, { connectionTimeout: CONNECTION_TIMEOUT_MS }),
                timeoutAfter(CONNECTION_TIMEOUT_MS, `Relay connection timed out: ${relay}`)
            ]);
            return relay;
        });
        const results = await Promise.allSettled(attempts);
        const connected = results
            .filter((result) => result.status === "fulfilled")
            .map((result) => result.value);
        if (connected.length === 0) throw new Error("No Nostr relay could be reached.");
        return connected;
    }

    subscribe() {
        this.subscription = this.pool.subscribeMany(
            this.relays,
            { kinds: [NIP46_KIND], "#p": [this.clientPubkey], since: Math.floor(Date.now() / 1000) - 30 },
            {
                onevent: (event) => void this.handleEvent(event),
                onclose: (reasons) => {
                    if (this.phase !== "success" && this.phase !== "idle") {
                        const reason = reasons.map((entry) => entry.reason).filter(Boolean).join(", ");
                        this.fail(new Error(reason || "All relay connections closed."));
                    }
                }
            }
        );
    }

    async handleEvent(event) {
        if (!this.clientSecret || !verifyEvent(event)) return;
        if (!event.tags.some((tag) => tag[0] === "p" && tag[1] === this.clientPubkey)) return;

        let plaintext;
        try {
            plaintext = decryptNIP46Payload(event.content, this.clientSecret, event.pubkey);
        } catch {
            return;
        }

        let response;
        try {
            response = parseNIP46Response(plaintext);
        } catch (error) {
            this.fail(error);
            return;
        }

        try {
            if (this.phase === "approval" && validateConnectResponse(response, this.connectID, this.pairingSecret)) {
                this.signerPubkey = event.pubkey;
                this.setPhase("connected");
                this.startCountdown(PUBLIC_KEY_TIMEOUT_MS, "Public-key request timed out.");
                await this.requestPublicKey();
                return;
            }
            if (this.phase === "public-key" && response.id === this.publicKeyRequestID) {
                if (response.error) throw new Error(errorMessage(response.error));
                const userPubkey = validateUserPubkey(response.result);
                this.succeed(userPubkey);
            }
        } catch (error) {
            this.fail(error);
        }
    }

    async requestPublicKey() {
        this.publicKeyRequestID = `get-public-key-${randomHex(12)}`;
        const event = createNIP46RequestEvent({
            clientSecret: this.clientSecret,
            signerPubkey: this.signerPubkey,
            id: this.publicKeyRequestID,
            method: "get_public_key",
            params: []
        });

        this.setPhase("public-key");
        const publishes = this.pool.publish(this.relays, event, { maxWait: CONNECTION_TIMEOUT_MS });
        try {
            await Promise.any(publishes);
        } catch {
            throw new Error("The public-key request could not be published to a relay.");
        }
    }

    succeed(userPubkey) {
        this.clearCountdown();
        this.phase = "success";
        this.setPhase("success");
        this.elements.npub.textContent = nip19.npubEncode(userPubkey);
        this.elements.hexPubkey.textContent = userPubkey;
        this.elements.success.hidden = false;
        this.elements.error.hidden = true;
        this.elements.statusText.textContent = "Connected securely";
        this.elements.statusDot.className = "tester-status-dot success";
    }

    fail(error) {
        this.clearCountdown();
        this.phase = "error";
        this.setBusy(false);
        this.elements.panel.hidden = false;
        this.elements.intro.hidden = true;
        this.elements.errorText.textContent = friendlyError(error);
        this.elements.error.hidden = false;
        this.elements.success.hidden = true;
        this.elements.statusText.textContent = "Needs attention";
        this.elements.statusDot.className = "tester-status-dot error";
    }

    setPhase(phase) {
        this.phase = phase;
        const order = ["relay", "approval", "connected", "public-key", "success"];
        const activeIndex = order.indexOf(phase);
        for (const step of this.elements.steps) {
            const index = order.indexOf(step.dataset.testStep);
            step.classList.toggle("active", index === activeIndex);
            step.classList.toggle("done", activeIndex > index || phase === "success");
        }
        for (const flow of this.elements.flowSteps) {
            flow.classList.toggle("active", flow.dataset.flowStep === phase || (
                phase === "public-key" && flow.dataset.flowStep === "connected"
            ));
        }
        const messages = {
            relay: "Connecting to relays",
            approval: "Waiting for approval in Signstr",
            connected: "Pairing authenticated",
            "public-key": "Approve the public-key request in Signstr",
            success: "Connected securely"
        };
        if (messages[phase]) this.elements.statusText.textContent = messages[phase];
        this.elements.statusDot.className = `tester-status-dot ${phase === "success" ? "success" : ""}`;
    }

    setBusy(busy, label = "Start NIP-46 test") {
        this.elements.start.disabled = busy;
        this.elements.start.textContent = busy ? label : "Start NIP-46 test";
    }

    startCountdown(duration, timeoutMessage) {
        this.clearCountdown();
        this.deadline = Date.now() + duration;
        const tick = () => {
            const remaining = Math.max(0, this.deadline - Date.now());
            const minutes = Math.floor(remaining / 60_000);
            const seconds = Math.floor((remaining % 60_000) / 1000);
            this.elements.countdown.textContent = `${minutes}:${seconds.toString().padStart(2, "0")}`;
            if (remaining === 0) this.fail(new Error(timeoutMessage));
        };
        tick();
        this.timer = setInterval(tick, 1000);
    }

    clearCountdown() {
        if (this.timer) clearInterval(this.timer);
        this.timer = null;
        this.deadline = null;
        this.elements.countdown.textContent = "—";
    }

    async copy(value, button) {
        try {
            await navigator.clipboard.writeText(value);
            const original = button.textContent;
            button.textContent = "Copied";
            setTimeout(() => { button.textContent = original; }, 1600);
        } catch {
            this.fail(new Error("Copying was blocked. Select the link or public key and copy it manually."));
        }
    }

    reset(showIntro = true) {
        this.clearCountdown();
        this.phase = "idle";
        this.subscription?.close();
        this.pool?.destroy();
        this.subscription = null;
        this.pool = null;
        this.clientSecret = null;
        this.signerPubkey = null;
        this.uri = null;
        if (!this.elements) return;
        this.elements.panel.hidden = true;
        this.elements.success.hidden = true;
        this.elements.error.hidden = true;
        this.elements.intro.hidden = !showIntro;
        this.elements.qr.getContext("2d")?.clearRect(0, 0, this.elements.qr.width, this.elements.qr.height);
        this.elements.statusText.textContent = "Ready to begin";
        this.elements.statusDot.className = "tester-status-dot";
        this.setBusy(false);
        for (const step of this.elements.steps) step.classList.remove("active", "done");
        for (const flow of this.elements.flowSteps) flow.classList.remove("active");
    }
}

function collectElements() {
    return {
        start: document.querySelector("#nip46-start"),
        reset: document.querySelector("#nip46-reset"),
        retry: document.querySelector("#nip46-retry"),
        intro: document.querySelector("#nip46-intro"),
        panel: document.querySelector("#nip46-panel"),
        qr: document.querySelector("#nip46-qr"),
        rawLink: document.querySelector("#nip46-raw-link"),
        openLink: document.querySelector("#nip46-open-link"),
        linkValue: document.querySelector("#nip46-link-value"),
        copyLink: document.querySelector("#nip46-copy-link"),
        copyNpub: document.querySelector("#nip46-copy-npub"),
        clientKey: document.querySelector("#nip46-client-key"),
        relayList: document.querySelector("#nip46-relays"),
        countdown: document.querySelector("#nip46-countdown"),
        statusText: document.querySelector("#nip46-status-text"),
        statusDot: document.querySelector("#nip46-status-dot"),
        success: document.querySelector("#nip46-success"),
        npub: document.querySelector("#nip46-npub"),
        hexPubkey: document.querySelector("#nip46-hex-pubkey"),
        error: document.querySelector("#nip46-error"),
        errorText: document.querySelector("#nip46-error-text"),
        steps: [...document.querySelectorAll("[data-test-step]")],
        flowSteps: [...document.querySelectorAll("[data-flow-step]")]
    };
}

if (typeof document !== "undefined") {
    document.addEventListener("DOMContentLoaded", () => {
        const elements = collectElements();
        if (!elements.start || !elements.panel) return;
        const session = new NIP46BrowserSession(elements);
        elements.start.addEventListener("click", () => void session.start());
        elements.reset.addEventListener("click", () => session.reset());
        elements.retry.addEventListener("click", () => void session.start());
        elements.copyLink.addEventListener("click", () => void session.copy(session.uri, elements.copyLink));
        elements.copyNpub.addEventListener("click", () => void session.copy(elements.npub.textContent, elements.copyNpub));
        addEventListener("beforeunload", () => session.reset(false));
    });
}
