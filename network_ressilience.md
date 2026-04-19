# Network Resilience & Cybersecurity Standards
### Brain_child — Complete Implementation Guide

---

## Part 1: Industry Standards for Network Resilience

To implement this professionally, your architecture must adopt these three standard patterns:

**Immediate State Transition (Optimistic UI vs. Loading State):** When the user clicks "Schedule", the button must instantly disable and show a loading indicator. Do not wait for the network to respond to update the UI.

**Circuit Breakers & Timeouts:** You cannot rely on default OS network timeouts (which can sometimes hang for 60+ seconds). You must enforce a strict client-side timeout (e.g., 8 seconds). If the server hasn't responded, the circuit breaks, the loading spinner stops, and a non-intrusive toast/alert appears.

**Idempotency (Crucial):** If a user clicks "Schedule", the network drops, and they click it again when the network returns, the server must know this is the same request, not a request for two meetings.

---

## Part 2: Hidden Cybersecurity Vulnerabilities & Mitigation

Because Brain_child is a zero-trust kiosk application, changing how you handle network latency introduces new attack vectors. Attackers frequently use Network Throttling (intentionally slowing down their own internet using tools like Charles Proxy or Clumsy) to exploit state-machine vulnerabilities.

---

### Threat 1: The "Two Generals' Problem" (State Desync)

**The Vulnerability:** The user clicks "Schedule Meeting." The request reaches your Node.js server, and the server schedules it. However, the response from the server is delayed by a slow network. Your Mac app hits its 8-second timeout, assumes failure, and tells the user "Network Error: Meeting not scheduled." The user is now desynced from the server state.

**The Exploit:** If this was a billing action ("Upgrade to Pro") or a secure exam submission, the user could mash the button multiple times, resulting in multiple server-side executions while the client thinks it failed.

**Mitigation (Idempotency Keys):** Every network-dependent button click must generate a unique UUID v4 (Idempotency Key) on the client. Send this in the headers: `X-Idempotency-Key: <UUID>`. The Node server caches this key for 24 hours. If the client retries the exact same request, the server says, "I already processed this key, here is the original success response," preventing duplicate actions.

---

### Threat 2: Resource Exhaustion & Thread Starvation (Button Mashing)

**The Vulnerability:** If the network is extremely slow (e.g., 2G speeds), a frustrated user might click the "Schedule Meeting" button 50 times in 10 seconds.

**The Exploit:** If your UI doesn't strictly lock the execution thread, the app will spawn 50 simultaneous network requests. When the network suddenly recovers, all 50 requests hit your Node.js server at the exact same millisecond, creating a localized Denial of Service (DoS) attack that could crash your app or throttle your backend.

**Mitigation (Debouncing & Strict Disabling):** The instant a button is clicked, the UI element must be strictly disabled at the state level (not just visually). Any subsequent clicks are swallowed until the first promise either resolves or throws a timeout exception.

---

### Threat 3: Information Disclosure via Error Handling

**The Vulnerability:** If the server is unreachable, developers often accidentally pipe the raw network error directly to the UI.

**The Exploit:** If an attacker deliberately blocks the connection to see how the app reacts, and your UI says `Error: ENOTFOUND api.brainchild.internal at 10.0.0.4`, you have just leaked your backend routing, internal IP architecture, and stack trace data.

**Mitigation (Sanitized Error Mapping):** Never pass raw NSError or Node.js error strings to the UI. You must have an Error Mapper utility.

- Raw Error: `Timeout exceeded 8000ms at /api/v1/schedule`
- UI Display: `"Unable to connect to the scheduling service. Please check your internet connection and try again."`

---

### Threat 4: Local Queue Manipulation (If you implement offline queues)

**The Vulnerability:** Many apps handle offline states by saving the request to a local database (like CoreData or SQLite) and saying, "We will schedule this when you reconnect."

**The Exploit:** Since your app runs on the user's hardware, an attacker could locate this offline queue file, modify the SQLite database using a hex editor, and change the queued payload before the internet reconnects.

**Mitigation:** Do not queue secure/state-mutating actions (like submitting an interview or billing) locally. If there is no internet, the action must hard-fail and ask the user to retry when online. Only queue non-critical data (like telemetry or logs), and even then, encrypt the local queue.

---

## Part 3: Appended — Additional Vulnerabilities & Mitigations

The following threats were not covered in the original document. They are equally critical for a zero-trust kiosk architecture and must be treated with the same priority as the threats above.

---

### Threat 5: Feature Enumeration via Connectivity Probing

**The Vulnerability:** The original design hides or shows network-dependent buttons based on whether the server is reachable. This creates an unintended side effect: by observing which UI elements appear and disappear, an attacker can passively map your entire backend service topology without ever authenticating.

**The Exploit:** An attacker sitting at a kiosk — or intercepting traffic with the same Charles Proxy or Clumsy tools described in Part 2 — selectively blocks different network routes and watches which buttons disappear. If "Schedule Meeting" vanishes when port 4001 is blocked, they now know a scheduling service runs on port 4001. If "Submit Exam" vanishes when a specific host is unreachable, they have identified that host as critical infrastructure. This reconnaissance costs the attacker nothing and requires no credentials.

**Mitigation (Role-based rendering, not connectivity-based rendering):** UI elements should be shown or hidden based solely on the authenticated user's role and permissions — data that comes from a validated JWT claim at login time, not from live connectivity probes. A button being visible does not mean the action will succeed; that is acceptable. What is not acceptable is using server reachability as a proxy for access control.

```js
// ❌ Leaks backend topology
if (await pingServer('api.brainchild.internal:4001')) showButton('schedule-meeting')

// ✓ Renders based on auth claims only — no topology disclosed
if (currentUser.permissions.includes('schedule:write')) showButton('schedule-meeting')
```

When the server is unreachable and the user clicks an enabled button, the error handling from Threat 3 handles communication — not the visibility of the button itself.

---

### Threat 6: Client-Side UI as a False Security Gate

**The Vulnerability:** Hiding or disabling a button is a UX convenience, not a security control. This distinction must be explicitly enforced at the architecture level — particularly in a zero-trust application where exam submission, billing, and scheduling carry real consequences.

**The Exploit:** Any developer-level user, QA engineer, or attacker with basic tools (Postman, curl, a browser DevTools console) can call your API endpoints directly, bypassing the UI entirely. If your only protection for a "Delete Exam Submission" action is that the button is hidden from non-admin users on the front end, that protection is completely ineffective. The API endpoint is still open.

This becomes especially dangerous in an Electron or Tauri-based desktop app, where the JavaScript bundle is locally accessible and can be inspected or patched by the attacker on their own machine.

**Mitigation (Server-side authorization on every endpoint, without exception):** Every protected API endpoint must independently verify the caller's identity and permissions on the server, regardless of what the client UI renders. This is the foundational principle of zero-trust architecture.

```js
// ✓ Server-side guard — must exist on every protected route
router.post('/api/v1/schedule', authenticate, authorize('schedule:write'), async (req, res) => {
  // handler
})

// authenticate: verifies JWT signature and expiry
// authorize('schedule:write'): checks that the token's claims include the required permission
```

No UI state, no button visibility, and no client-side flag can substitute for this check. The server must behave as if the UI does not exist.

---

### Threat 7: Stale Authentication Token on Slow Networks

**The Vulnerability:** On a slow or intermittent network, significant time elapses between the user clicking a button and the request actually being dispatched. If a short-lived JWT (e.g., a 15-minute access token) expires during this window, the request fires with an expired credential. Without proper handling, the server returns a 401 and the app has no recovery path.

**The Exploit:** An attacker who can deliberately slow the network (again using throttling tools) can force a token expiry window and then observe how the app responds to a 401. If the app surfaces a raw error, it may leak token format, expiry duration, or authentication service endpoints. If the app crashes or enters a broken state, it creates a denial-of-service condition: the user is locked out until they manually restart and re-authenticate.

Additionally, if the app naively retries the request with the same expired token (common in simple retry loops), the server sees repeated 401s from the same session and may lock the account under a brute-force protection policy — locking out a legitimate user.

**Mitigation (Transparent token refresh interceptor):** Implement a single centralized HTTP interceptor that catches 401 responses before they reach any component. The interceptor silently requests a new access token using the refresh token, then replays the original failed request exactly once with the new credential. Only if the refresh itself fails (expired refresh token, revoked session) should an auth error be surfaced to the user — and even then, via a clean "Your session has expired, please sign in again" message, not a raw error.

```js
// Module-scoped singleton — shared across every concurrent 401
let refreshPromise = null

axiosInstance.interceptors.response.use(
  response => response,
  async error => {
    const original = error.config

    if (error.response?.status === 401 && !original._retry) {
      original._retry = true

      // If no refresh is in flight, start one wrapped in a hard timeout.
      // Every subsequent 401 that arrives while the refresh is pending
      // awaits the same promise instead of spawning a second refresh call.
      if (!refreshPromise) {
        refreshPromise = new Promise((resolve, reject) => {
          const timer = setTimeout(
            () => reject(new Error('Token refresh timed out')),
            10_000   // adjust to match your auth SLA
          )
          authService.refreshAccessToken()
            .then(token => { clearTimeout(timer); resolve(token) })
            .catch(err  => { clearTimeout(timer); reject(err)   })
        }).finally(() => {
          // Always clear after settlement so the next genuine
          // session expiry starts a fresh refresh cycle.
          refreshPromise = null
        })
      }

      try {
        const newToken = await refreshPromise
        axiosInstance.defaults.headers.common['Authorization'] = `Bearer ${newToken}`
        original.headers['Authorization'] = `Bearer ${newToken}`
        return axiosInstance(original)
      } catch {
        // Refresh failed or timed out — surface a safe message (see Threat 3)
        return Promise.reject(mapToSafeError(error))
      }
    }

    // Non-401 errors or already-retried requests
    return Promise.reject(mapToSafeError(error))
  }
)
```

This must be implemented at a single point — not duplicated per feature — so token refresh behaviour is consistent across the entire application.

---

### Threat 8: Dangling Promises & Component Unmount Crashes

**The Vulnerability:** The 8-second circuit breaker described in Part 1 correctly stops the UI from waiting forever. However, it does not cancel the in-flight network request. The request continues running in the background. If the user navigates away from the screen while the request is pending — which is natural on a slow network — the promise eventually resolves or rejects and attempts to update the state of a component that no longer exists.

**The Exploit:** In React-based Electron apps, this produces the well-known "Can't perform a React state update on an unmounted component" error. In severe cases (especially with global state managers or IPC channels in Electron), it can corrupt application state or cause the renderer process to crash entirely — producing a visible white screen or full app restart. On a kiosk, this is a significant operational failure.

**Mitigation (AbortController with lifecycle cleanup):** Every network request must be tied to an `AbortController`. The controller's signal is passed to `fetch()`. When the component unmounts, the circuit breaker timeout fires, or the user explicitly cancels, `controller.abort()` is called. This immediately terminates the in-flight request and causes the promise to reject with an `AbortError`, which must be caught and silently discarded — it is not a user-facing error.

```js
// React hook pattern
useEffect(() => {
  const controller = new AbortController()

  // Flag set before the timeout calls controller.abort() so the catch block
  // can tell apart a circuit-breaker abort (needs UX) from a silent
  // unmount/user-cancel abort (must be discarded without surfacing anything).
  let isTimeoutAbort = false

  const timeoutId = setTimeout(() => {
    isTimeoutAbort = true   // mark before abort so the flag is set when catch runs
    controller.abort()
  }, 8000)

  fetch('/api/v1/schedule', {
    method: 'POST',
    signal: controller.signal,
    headers: { 'X-Idempotency-Key': idempotencyKey }
  })
    .then(handleSuccess)
    .catch(err => {
      if (err.name === 'AbortError') {
        if (isTimeoutAbort) {
          // Circuit breaker fired — stop the spinner and show the non-intrusive
          // toast described in Part 1 ("Taking longer than expected…").
          handleNetworkError(err)
        }
        // Otherwise: unmount or explicit user cancel — discard silently,
        // no toast, no state update on a component that no longer exists.
        return
      }
      handleNetworkError(err)  // map to safe user message (Threat 3)
    })
    .finally(() => clearTimeout(timeoutId))

  return () => {
    // isTimeoutAbort stays false here, so the catch above stays silent.
    controller.abort()    // fires on unmount, navigating away, or re-render
    clearTimeout(timeoutId)
  }
}, [])
```

For Electron IPC calls (where `fetch` is not used), the equivalent is tracking pending IPC invocations in a ref and sending a cancellation IPC message to the main process on cleanup.

---

### Threat 9: Half-Open Circuit Breaker (Missing Recovery State)

**The Vulnerability:** The circuit breaker described in Part 1 handles two states: closed (working normally) and open (broken after timeout). This is incomplete. Without a recovery mechanism, once the circuit opens — due to a brief server restart, a momentary network drop, or a deployment — the feature remains permanently disabled until the user manually retries or restarts the app. On a kiosk with unattended operation, this could mean hours of downtime for a recoverable condition.

**The Exploit:** A sophisticated attacker who knows your app uses a simple open/closed circuit breaker can cause a brief, targeted disruption (a few seconds of packet loss) to trip the circuit, then step back. The feature stays broken long after the network has recovered, without any further effort from the attacker.

**Mitigation (Three-state circuit breaker with exponential backoff):** Implement a proper three-state circuit breaker. After the circuit opens, it must not stay open permanently. It enters a "half-open" state after a delay, sends a single probe request, and either fully closes (recovers) or re-opens (stays broken) based on the result. The delay before each probe must use exponential backoff with jitter to avoid synchronized retries hammering a recovering server.

```
States:
  CLOSED    → Normal operation. All requests go through.
  OPEN      → Failure detected. Requests blocked immediately with cached error.
  HALF-OPEN → Probe state. One test request is allowed through.
                If it succeeds  → transition to CLOSED
                If it fails     → transition to OPEN, double the backoff delay

Backoff schedule (with ±500ms random jitter):
  After 1st failure:  wait 2s  before half-open probe
  After 2nd failure:  wait 4s
  After 3rd failure:  wait 8s
  After 4th+ failure: wait 16s (cap here — do not increase further)
```

The user should be shown a passive, non-blocking indicator during the half-open probe ("Reconnecting…") so they know the app is attempting recovery without requiring any action from them.

---

## Summary: Complete Threat & Mitigation Matrix

| # | Threat | Severity | Status |
|---|--------|----------|--------|
| 1 | Two Generals' Problem — state desync | Critical | Covered: Idempotency Keys |
| 2 | Resource exhaustion via button mashing | High | Covered: Strict state-level disable |
| 3 | Information disclosure via raw errors | High | Covered: Sanitized error mapper |
| 4 | Local queue payload manipulation | High | Covered: Encrypt queue, hard-fail secure actions |
| 5 | Feature enumeration via connectivity probing | High | **Appended: Role-based rendering only** |
| 6 | Client-side UI as false security gate | Critical | **Appended: Server-side auth on every endpoint** |
| 7 | Stale auth token on slow networks | High | **Appended: Transparent refresh interceptor** |
| 8 | Dangling promises and unmount crashes | Medium | **Appended: AbortController with lifecycle cleanup** |
| 9 | Incomplete circuit breaker — no recovery state | Medium | **Appended: Three-state breaker with backoff** |

---
