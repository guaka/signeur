## iOS NIP-46 App Plan (drop into a fresh repo)

### 0) Repo structure (start clean)
Create these top-level folders:

- `App/` – iOS app entry, navigation, screens
- `Domain/` – pure models + protocol semantics (no UIKit/SwiftUI)
- `Data/` – networking, persistence (Keychain, storage), bridges
- `Wallet/` – signing + identity management (Keychain/Secure Enclave integration)
- `NIP46/` – request/response types, validation, session state machine
- `Shared/` – utilities (logging redaction, timeouts, formatting)
- `Tests/` – unit + integration tests
- `Scripts/` – helper scripts (lint/test/build)

### 1) Decide your app flow (and encode it as states)
Implement a single session state machine that the UI binds to.

**Session states:**
- `idle`
- `request_received`
- `awaiting_user_decision`
- `signing`
- `sending_response`
- `completed_success`
- `completed_error`
- `expired`
- `cancelled`

**Events:**
- `onRequestArrived`
- `onApprove`
- `onReject`
- `onSignComplete`
- `onSendSuccess`
- `onSendFailure`
- `onTimeout`
- `onCancel`

UI should never update from random callbacks—only from state transitions.

### 2) Define protocol contracts (NIP-46 core)
In `NIP46/` add:

- `NIP46Request` model (parsed from incoming payload)
- `NIP46Response` model (built to send back)
- `NIP46Method` enum / supported methods list
- `NIP46Validator`:
  - field presence/type checks
  - method support checks
  - signature/message payload sanity checks
- `NIP46Session`:
  - session id / correlation id mapping
  - expiry time
  - remote info used for preview + verification
- `NIP46SessionManager`:
  - queue multiple concurrent requests (or explicitly reject with a UI message)
  - timeout handling
  - idempotency (duplicate request ids don’t create duplicate prompts)

**Non-negotiable:** strict validation before you ever show “Approve”.

### 3) Implement “hard to trick” consent UX
In `App/` build these screens/components:

- `IncomingRequestView` (main approval screen)
  - remote party identity clearly displayed
  - requested method + scope summary
  - a “details” expander with raw payload preview (redacted/escaped)
- `ApprovalActions`:
  - Approve → calls `sessionManager.handleApprove(requestId)`
  - Reject → calls `sessionManager.handleReject(requestId)`

Also add a `LoadingSigningView` that is shown only in `signing` / `sending_response`.

### 4) Signing architecture (keep it narrow and safe)
In `Wallet/`:

- `IdentityStore`
  - list/select identities
  - persist active identity choice
- `Signer`
  - `sign(message, identity)` -> returns signature bytes
  - zero logging of secrets/signatures in plain text
- `AuthorizationGuard`
  - only allow signing when the state machine is in `awaiting_user_decision` with an approved request
  - block signing calls from anywhere else

If you support multiple identities, the session must bind to exactly one identity selection at approval time.

### 5) Networking layer (response sending)
In `Data/`:

- `NIP46Transport`
  - `sendResponse(response, toEndpoint)` (method depends on your NIP-46 flow)
  - timeouts + retries (bounded)
  - clear error mapping:
    - user rejected
    - protocol invalid
    - network timeout
    - transport failure

Make transport return structured errors so your UI can show a meaningful message.

### 6) Input entry points (deep link / QR)
In `App/` handle:
- deep link URL parsing
- QR scan payload parsing (if you have it)
- route into `NIP46SessionManager.onRequestArrived(...)`

**Edge handling:**
- malformed payload → show “Unsupported request”
- missing fields → reject with “Invalid request”
- duplicate sessions → dedupe by correlation id

### 7) Persistence (optional but useful)
Store only what you must:
- active identity selection (Keychain/UserDefaults)
- recent request history (optional, and never store secrets)

Avoid storing raw request/signature payloads unless you have a specific user-facing reason.

### 8) Testing plan (make it wallet-grade)
In `Tests/`:

**Unit tests (fast):**
- validator rejects malformed requests
- validator rejects unsupported methods
- session expiry transitions to `expired`
- duplicate request id doesn’t create multiple approval prompts
- reject/approve produce correct response shape

**Integration tests (mock transport):**
- approve → signing called → sendResponse called
- timeout during sending → `completed_error` with timeout reason
- user cancels in `awaiting_user_decision` → cancelled path

**Snapshot tests (UI):**
- approval screen renders correct summary for sample requests
- redaction rules work (no accidental raw secrets)

### 9) Logging + observability (but don’t leak)
In `Shared/` implement:
- `RedactedLogger`
  - redacts key material, signatures, payload blobs
  - logs only ids, timestamps, status codes, and high-level errors

### 10) Implementation order (so you finish)
1. **Build state machine + models** (no UI yet)
2. **Implement strict validator**
3. **Implement approval UI** (no signing yet; stub signer)
4. **Implement signer integration** (Keychain/Secure Enclave path)
5. **Implement transport + response sending**
6. **Add deep link/QR entry**
7. **Add full test suite**
8. **Polish error UX + edge cases**

### 11) “Definition of done” for a “good” iOS NIP-46 app
- Incoming request always results in a terminal state (success or a reasoned error)
- No approval happens without validation + preview
- Signing is only possible after user approval, by the current approved session
- Session timeouts work
- Duplicate / concurrent requests don’t break UX
- Transport errors show actionable messages

---

If you tell me which NIP-46 variant you’re targeting (and how you’re receiving/sending—deep link, websocket, HTTP callback, etc.), I’ll turn this into a concrete file-by-file blueprint (Swift package layout, key protocols, and example state machine interfaces) that you can paste into your repo.