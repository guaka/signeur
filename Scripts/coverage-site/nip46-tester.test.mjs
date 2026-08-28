import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import test from "node:test";
import {
    buildNostrConnectURI,
    connectRequestID,
    createNIP46RequestEvent,
    decryptNIP46Payload,
    encryptNIP46Payload,
    friendlyError,
    NIP46BrowserSession,
    parseNIP46Response,
    publicKeyFromSecret,
    validateConnectResponse,
    validateUserPubkey
} from "./nip46-tester.source.mjs";

const clientPubkey = "a".repeat(64);
const userPubkey = "b".repeat(64);

function classList() {
    const values = new Set();
    return {
        toggle(value, enabled) { enabled ? values.add(value) : values.delete(value); },
        remove(...items) { for (const item of items) values.delete(item); },
        contains(value) { return values.has(value); }
    };
}

function browserElements() {
    const steps = ["relay", "approval", "connected", "public-key", "success"]
        .map((phase) => ({ dataset: { testStep: phase }, classList: classList() }));
    const flowSteps = ["relay", "approval", "connected", "public-key", "success"]
        .map((phase) => ({ dataset: { flowStep: phase }, classList: classList() }));
    return {
        start: { disabled: false, textContent: "" },
        intro: { hidden: false },
        panel: { hidden: true },
        qr: { width: 272, height: 272, getContext: () => ({ clearRect() {} }) },
        countdown: { textContent: "—" },
        statusText: { textContent: "" },
        statusDot: { className: "" },
        success: { hidden: true },
        npub: { textContent: "" },
        hexPubkey: { textContent: "" },
        error: { hidden: true },
        errorText: { textContent: "" },
        steps,
        flowSteps
    };
}

test("builds a Signstr-compatible nostrconnect URI", () => {
    const uri = buildNostrConnectURI({
        clientPubkey,
        relays: ["wss://relay.one", "wss://relay.two"],
        secret: "pairing-secret",
        name: "Test client",
        url: "https://example.com/test"
    });
    const parsed = new URL(uri);

    assert.equal(parsed.protocol, "nostrconnect:");
    assert.equal(parsed.hostname, clientPubkey);
    assert.deepEqual(parsed.searchParams.getAll("relay"), ["wss://relay.one", "wss://relay.two"]);
    assert.equal(parsed.searchParams.get("secret"), "pairing-secret");
    assert.equal(parsed.searchParams.get("perms"), "get_public_key,ping");
    assert.equal(parsed.searchParams.get("name"), "Test client");
    assert.equal(parsed.searchParams.get("url"), "https://example.com/test");
});

test("rejects incomplete connection URI inputs", () => {
    assert.throws(() => buildNostrConnectURI({ clientPubkey: "bad", relays: ["wss://relay.one"], secret: "x" }));
    assert.throws(() => buildNostrConnectURI({ clientPubkey, relays: [], secret: "x" }));
    assert.throws(() => buildNostrConnectURI({ clientPubkey, relays: ["wss://relay.one"], secret: "" }));
});

test("matches Signstr's deterministic connect response ID", async () => {
    const secret = "pairing-secret";
    const expected = "connect-" + createHash("sha256")
        .update(`${clientPubkey}:${secret}`)
        .digest("hex")
        .slice(0, 32);

    assert.equal(await connectRequestID(clientPubkey, secret, webcrypto.subtle), expected);
});

test("parses valid success and rejection responses", () => {
    assert.deepEqual(parseNIP46Response('{"id":"one","result":"pong"}'), { id: "one", result: "pong" });
    assert.deepEqual(parseNIP46Response('{"id":"two","error":{"code":4001,"message":"userRejected"}}'), {
        id: "two",
        error: { code: 4001, message: "userRejected" }
    });
});

test("rejects malformed response payloads", () => {
    assert.throws(() => parseNIP46Response("not json"), /not valid JSON/);
    assert.throws(() => parseNIP46Response('{"result":"pong"}'), /malformed/);
    assert.throws(() => parseNIP46Response('{"id":"x","result":42}'), /malformed result/);
    assert.throws(() => parseNIP46Response('{"id":"x","error":42}'), /malformed error/);
});

test("authenticates an encrypted NIP-46 request and response round trip", () => {
    assert.equal(validateConnectResponse({ id: "other", result: "secret" }, "expected", "secret"), false);
    assert.equal(validateConnectResponse({ id: "expected", result: "secret" }, "expected", "secret"), true);
    assert.throws(
        () => validateConnectResponse({ id: "expected", result: "wrong" }, "expected", "secret"),
        /expected pairing secret/
    );
    assert.throws(
        () => validateConnectResponse(
            { id: "expected", error: { code: 4001, message: "userRejected" } },
            "expected",
            "secret"
        ),
        /userRejected/
    );

    const clientSecret = new Uint8Array(32);
    const signerSecret = new Uint8Array(32);
    clientSecret[31] = 1;
    signerSecret[31] = 2;
    const generatedClientPubkey = publicKeyFromSecret(clientSecret);
    const signerPubkey = publicKeyFromSecret(signerSecret);
    const request = createNIP46RequestEvent({
        clientSecret,
        signerPubkey,
        id: "get-public-key-test",
        method: "get_public_key",
        createdAt: 1_700_000_000
    });
    const decryptedRequest = JSON.parse(
        decryptNIP46Payload(request.content, signerSecret, generatedClientPubkey)
    );
    assert.deepEqual(decryptedRequest, { id: "get-public-key-test", method: "get_public_key", params: [] });

    const responseBody = JSON.stringify({ id: decryptedRequest.id, result: signerPubkey });
    const responseCiphertext = encryptNIP46Payload(responseBody, signerSecret, generatedClientPubkey);
    const decryptedResponse = parseNIP46Response(
        decryptNIP46Payload(responseCiphertext, clientSecret, signerPubkey)
    );
    assert.equal(validateUserPubkey(decryptedResponse.result), signerPubkey);
});

test("validates and presents public-key and common error states", () => {
    assert.equal(validateUserPubkey(userPubkey), userPubkey);
    assert.throws(() => validateUserPubkey("npub-not-hex"), /invalid user public key/);
    assert.equal(friendlyError(new Error("userRejected")), "The request was declined in Signstr.");
    assert.match(friendlyError(new Error("Pairing timed out.")), /No response arrived/);
    assert.match(friendlyError(new Error("No Nostr relay could be reached.")), /could not reach a Nostr relay/);
    assert.match(friendlyError(new Error("expected pairing secret")), /could not be authenticated/);
});

test("renders browser progress and a connected npub", () => {
    const elements = browserElements();
    const session = new NIP46BrowserSession(elements);

    session.setPhase("public-key");
    assert.equal(elements.steps[3].classList.contains("active"), true);
    assert.equal(elements.steps[2].classList.contains("done"), true);
    assert.equal(elements.statusText.textContent, "Approve the public-key request in Signstr");

    session.succeed(userPubkey);
    assert.equal(elements.success.hidden, false);
    assert.equal(elements.error.hidden, true);
    assert.match(elements.npub.textContent, /^npub1/);
    assert.equal(elements.hexPubkey.textContent, userPubkey);
    assert.equal(elements.statusDot.className, "tester-status-dot success");
});

test("renders actionable browser errors and resets sensitive session state", () => {
    const elements = browserElements();
    const session = new NIP46BrowserSession(elements);
    let subscriptionClosed = false;
    let poolDestroyed = false;
    session.clientSecret = new Uint8Array([1]);
    session.signerPubkey = userPubkey;
    session.subscription = { close() { subscriptionClosed = true; } };
    session.pool = { destroy() { poolDestroyed = true; } };

    session.fail(new Error("userRejected"));
    assert.equal(elements.panel.hidden, false);
    assert.equal(elements.error.hidden, false);
    assert.equal(elements.errorText.textContent, "The request was declined in Signstr.");
    assert.equal(elements.statusDot.className, "tester-status-dot error");

    session.reset();
    assert.equal(subscriptionClosed, true);
    assert.equal(poolDestroyed, true);
    assert.equal(session.clientSecret, null);
    assert.equal(session.signerPubkey, null);
    assert.equal(elements.panel.hidden, true);
    assert.equal(elements.intro.hidden, false);
});
