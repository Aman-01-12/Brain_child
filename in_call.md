# In-Call Network Resilience Framework
### inter — Video Call Implementation Guide

---

## Context: How in-call differs from the existing framework

The existing framework is built around **request/response HTTP actions** — discrete mutations like scheduling a meeting. The in-call session is a **stateful, continuous stream** where:

- There is no "retry the request" — the stream must *survive* the disruption without restarting the session.
- Latency budgets are measured in milliseconds, not seconds. The 8-second circuit breaker becomes a 1-second probe in some cases.
- Three planes run simultaneously and are interdependent. If the signaling plane dies, the media plane becomes unrecoverable without intervention.

---

## Plane 1 — Signaling (WebSocket)

This is the closest to the existing framework. The WebSocket carries SDP offers/answers, ICE candidates, and control messages (mute, layout changes, participant events). It must stay alive or reconnect fast enough that the media plane can recover.

### WS Heartbeat (ping/pong every 5 s)

Unlike HTTP, a broken TCP connection can appear open to the client for 30–90 seconds without a keepalive. The socket must send a ping frame every 5 seconds and enforce a 7-second pong timeout. If the pong does not arrive, treat the connection as dead immediately — do not wait for the OS.

### Reconnect Finite State Machine (FSM)

Extends Threat 9 (three-state circuit breaker) into an in-call variant:

```
States:
  CONNECTED    → Normal operation. Signaling flows freely.
  RECONNECTING → Disconnect detected. Exponential backoff probes.
  RECOVERED    → Socket re-established. Replay missed messages.

Backoff schedule (with ±500ms random jitter):
  After 1st disconnect:  wait 2s  before probe
  After 2nd disconnect:  wait 4s
  After 3rd disconnect:  wait 8s
  After 4th+ disconnect: wait 16s (cap — do not increase further)
```

The in-call session ID must be preserved across reconnects so the server can resume the session rather than create a new one.

### Signaling Message Queue with Sequence Numbers

Every message sent over the WebSocket must carry a monotonically increasing sequence number and must be buffered client-side. On reconnect, the client sends its last acknowledged sequence number and the server replays any missed messages. This is the in-call equivalent of Threat 1 (Two Generals' Problem) — a mute command sent during a disconnect must not be silently dropped.

```js
// Client-side message envelope
{
  seq: 42,                        // monotonically increasing
  sessionId: "<in-call-session-id>",
  type: "mute",
  payload: { participantId: "..." }
}

// On reconnect, send last-known ACK
socket.send({ type: "replay-from", lastAckedSeq: 38 })
```

### In-Call Token Refresh

Threat 7 (stale auth token) applies with extra urgency here. A long call can easily exceed a 15-minute access token lifetime. The transparent refresh interceptor must be active on the signaling socket, but with one critical addition: refresh must happen **proactively** — at 80% of the token's lifetime — not reactively after a 401. A reactive refresh mid-call causes a 1–3 second signaling gap that can trigger an ICE restart cascade.

```js
// Proactive refresh — do not wait for a 401 during a live call
const TOKEN_REFRESH_THRESHOLD = 0.8

function scheduleProactiveRefresh(tokenExpiresAt) {
  const now = Date.now()
  const lifetime = tokenExpiresAt - now
  const refreshAt = lifetime * TOKEN_REFRESH_THRESHOLD

  setTimeout(async () => {
    await refreshAccessToken()     // silent, no UI disruption
  }, refreshAt)
}
```

### Sanitized Error Handling for Signaling

Threat 3 (information disclosure) is especially dangerous for signaling failures. Raw WebSocket close codes, SDP fragments, and ICE candidate strings must never appear in the UI.

| Raw value | UI display |
|-----------|------------|
| `4008 Session Expired` | "Your connection was interrupted. Reconnecting…" |
| `1006 Abnormal Closure` | "Connection lost. Attempting to reconnect…" |
| `SDP parse error at line 14` | "Unable to establish call. Please try again." |

---

## Plane 2 — Real-Time Transport (WebRTC / UDP)

WebRTC uses UDP, which is connectionless — there is no TCP teardown event, so failure cannot be detected the same way. The RTCP stats pipeline must be instrumented to know when the connection is degraded.

### ICE Restart on Path Failure

ICE (Interactive Connectivity Establishment) selects the best network path between peers at call start. When that path fails mid-call — due to a Wi-Fi handoff, NAT timeout, or VPN reconnect — the existing DTLS session is still valid but packets are going nowhere. The fix is an **ICE restart**: the offerer generates a new ICE `ufrag`/`pwd`, triggers a new SDP offer/answer exchange over the signaling plane, and WebRTC re-probes all candidate paths.

The client must detect this condition and automatically trigger an ICE restart:

```js
// Trigger condition: no RTCP receiver reports for 2+ seconds
const stats = await peerConnection.getStats()

stats.forEach(report => {
  if (report.type === 'inbound-rtp') {
    const gap = Date.now() - report.lastPacketReceivedTimestamp
    if (gap > 2000) triggerIceRestart()
  }
})

async function triggerIceRestart() {
  const offer = await peerConnection.createOffer({ iceRestart: true })
  await peerConnection.setLocalDescription(offer)
  signalingSocket.send({ type: 'sdp-offer', sdp: offer.sdp })
}
```

### TURN Server Fallback

In restrictive network environments (corporate firewalls, symmetric NATs), direct peer-to-peer UDP may be blocked. TURN must be configured with both UDP and TCP/TLS (port 443) endpoints — the TLS endpoint is indistinguishable from HTTPS traffic and penetrates almost every firewall.

```js
// ICE server config — order matters, direct paths tried first
const iceServers = [
  { urls: 'stun:stun.example.com:3478' },
  {
    urls: [
      'turn:turn.example.com:3478?transport=udp',
      'turn:turn.example.com:3478?transport=tcp',
      'turns:turn.example.com:443?transport=tcp'   // TLS on 443 — penetrates most firewalls
    ],
    username: '<credential>',
    credential: '<credential>'
  }
]
```

If ICE fails to establish a direct path within 5 seconds, the connection should fall back to TURN automatically without user intervention.

### Congestion Control and Bitrate Adaptation

WebRTC's built-in GCC (Google Congestion Control) algorithm continuously monitors one-way delay and packet loss to estimate available bandwidth, then signals the sender via REMB (Receiver Estimated Maximum Bitrate) messages. The media server or SFU must honor these signals.

Degradation cascade (each step triggered at sustained loss >5% for 3 seconds):

```
Full HD (1080p) → 720p → 480p → 360p → audio-only
```

### RTCP Stats Pipeline (1-second probe)

`RTCPeerConnection.getStats()` must be polled on a 1-second interval. Track:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Packet loss % | >5% for 3 s | Drop one video tier |
| Packet loss % | >30% for 5 s | Switch to audio-only |
| Round-trip time | >500 ms | Reduce encoder bitrate |
| Jitter | >100 ms | Expand jitter buffer |

```js
setInterval(async () => {
  const stats = await peerConnection.getStats()
  const metrics = extractMetrics(stats)   // loss, RTT, jitter, bitrate
  adaptQuality(metrics)
  updateQualityHUD(metrics)
}, 1000)
```

### NACK and Forward Error Correction (FEC)

For packet loss below ~15%, the browser's built-in NACK mechanism handles recovery by asking the sender to retransmit a missing packet.

For loss above 15%, NACK retransmission latency is too high for real-time use. Enable FEC instead:

- **Audio**: Opus `useinbandfec=1` — redundant audio data packed into each frame
- **Video**: RED/ULPFEC — redundant video data allows reconstruction without a retransmit round-trip

```
SDP negotiation for FEC:
  a=rtpmap:116 red/90000
  a=rtpmap:117 ulpfec/90000
  a=fmtp:100 useinbandfec=1     ← Opus audio FEC
```

### Simulcast / SVC

Publish multiple spatial and temporal resolution layers simultaneously. The SFU selects which layer to forward to each receiver based on their reported network conditions — without requiring the sender to renegotiate or restart encoding.

```
Simulcast layers:
  rid=high   max-width=1280 max-height=720  max-fr=30
  rid=mid    max-width=640  max-height=360  max-fr=15
  rid=low    max-width=320  max-height=180  max-fr=7.5
```

---

## Plane 3 — Media Data (Streams)

This plane is about keeping audio and video *perceptually continuous* even when packets are late, lost, or the network is constrained.

### Adaptive Jitter Buffer

Network packets arrive with variable delay (jitter). A jitter buffer holds incoming packets briefly before playing them out, absorbing that variance. The buffer must be *adaptive* — starting at around 20 ms and expanding up to 200 ms as jitter increases.

Do not disable or override the browser's default adaptive jitter buffer mode. Do not insert silence frames on packet loss — see PLC below.

### Packet Loss Concealment (PLC) and Comfort Noise Generation (CNG)

When a packet is lost and NACK/FEC cannot recover it, the Opus codec uses PLC to synthesize a plausible continuation of the waveform from prior context — filling the gap with a brief extrapolation rather than silence or a click. CNG fills longer gaps with synthetic background noise that matches the detected ambient noise profile.

These are handled by the Opus decoder automatically and must not be disabled. The media pipeline must not insert silence frames on packet loss.

### Codec Negotiation and Fallback

SDP negotiation must list codecs in preference order:

| Type | Priority order |
|------|---------------|
| Video | VP9 → VP8 → H.264 |
| Audio | Opus → G.711 |

The H.264 and G.711 fallbacks ensure interoperability with constrained clients or hardware encoders. If a mid-call renegotiation is needed (e.g., a legacy device joins), the SDP re-offer must complete without dropping existing participants.

### DTLS-SRTP (End-to-End Media Encryption)

Every media stream must be encrypted using DTLS-SRTP. The DTLS handshake happens during ICE establishment and must be verified against the certificate fingerprint in the SDP.

The signaling plane must deliver SDP over an authenticated WebSocket channel. If the signaling can be tampered with, the DTLS fingerprint can be replaced and the media stream man-in-the-middled. This is the in-call equivalent of Threat 6 (client-side as false security gate) — the server must enforce that DTLS fingerprints match the authenticated session.

```
SDP fingerprint verification flow:
  1. Server issues session token containing expected DTLS fingerprint hash
  2. Client receives SDP offer over authenticated WS
  3. Client verifies SDP fingerprint matches token — reject if mismatch
  4. DTLS handshake proceeds only on match
```

### DSCP QoS Tagging

On networks that support differentiated services, RTP media packets should be tagged with DSCP EF (Expedited Forwarding, value 46) to receive priority treatment in enterprise routers.

```
DSCP markings:
  RTP audio:  EF  (46) — highest priority, lowest latency queue
  RTP video:  AF41 (34) — assured forwarding, high priority
  RTCP:       AF41 (34) — keep with video for accurate feedback
  Signaling:  CS0  (0)  — best effort (TCP, can absorb latency)
```

### Degraded-Call UX

When the RTCP stats pipeline detects sustained high loss (>30% for 5+ seconds), the app must proactively switch to audio-only mode and show a non-blocking indicator ("Video paused to improve call quality"). This is not a failure state — it is a deliberate quality preservation decision. The user must have a clear, single-tap option to attempt to restore video.

```js
// Degradation state machine
function adaptQuality({ lossPercent, durationMs }) {
  if (lossPercent > 30 && durationMs > 5000) {
    disableVideoTrack()
    showQualityBanner('Video paused to improve call quality')
  } else if (lossPercent < 5 && currentMode === 'audio-only') {
    showRestoreOption('Restore video')
  }
}
```

---

## Cross-Cutting — UX & Security

### In-Call Quality HUD

Expose a minimal, non-intrusive quality indicator in the call UI — a single icon (green / amber / red) derived from the RTCP stats every second. This is the in-call equivalent of the "Reconnecting…" passive indicator from Threat 9 (half-open circuit breaker). Users must never be confused about whether their call is degraded or their microphone is muted.

| Icon state | Condition |
|------------|-----------|
| Green | Loss <2%, RTT <150 ms |
| Amber | Loss 2–10%, or RTT 150–400 ms |
| Red | Loss >10%, or RTT >400 ms, or ICE restarting |

### No Server-Side Information Leakage

SDP bodies, ICE candidate strings (which contain private IP addresses), DTLS fingerprints, and WebSocket close reason strings must never be surfaced to the UI layer or logged to a client-accessible log.

```
// ❌ Leaks private network topology
ICE candidate: candidate:1 1 UDP 2113937151 192.168.1.50 54321 typ host

// ✓ Strip from all UI error paths and client logs
UI display: "Establishing connection…" (no candidate details)
```

This is a direct extension of Threat 3 (information disclosure). An exposed ICE candidate reveals private IP addresses and the user's internal network structure.

### Server-Side Call Authorization

Threat 6 (server-side auth on every endpoint) must apply to every call control action: joining, muting a participant, ending the call, and changing layout. The server must validate JWT claims on every action regardless of what the client UI shows.

```js
// Every call control action must be independently authorized on the server
router.post('/api/v1/call/:sessionId/mute', authenticate, authorize('call:moderate'), async (req, res) => {
  // handler
})

router.post('/api/v1/call/:sessionId/end', authenticate, authorize('call:end'), async (req, res) => {
  // handler
})

// authenticate: verifies JWT signature and expiry
// authorize('call:moderate'): checks token claims include the required permission
```

A participant who has been muted by the host must not be able to re-enable their audio by sending a raw signaling message.

---

## Summary: Complete Threat & Mitigation Matrix

| # | Threat | Plane | Severity | Mitigation |
|---|--------|-------|----------|------------|
| C1 | WS disconnect — silent call freeze | Signaling | Critical | Heartbeat ping/pong + reconnect FSM |
| C2 | Missed signaling messages during disconnect | Signaling | Critical | Seq-num queue + server-side replay |
| C3 | Auth token expiry mid-call | Signaling | High | Proactive refresh at 80% TTL |
| C4 | SDP/ICE candidate info disclosure | Signaling | High | Sanitized error mapper for WS close codes |
| C5 | NAT timeout / path failure mid-call | WebRTC/UDP | Critical | Auto ICE restart on RTCP silence >2 s |
| C6 | Firewall blocks UDP entirely | WebRTC/UDP | High | TURN TCP/TLS on port 443 fallback |
| C7 | Network congestion → frozen video | WebRTC/UDP | High | GCC + REMB + adaptive bitrate cascade |
| C8 | Packet loss → audio/video glitches | Media | High | NACK (low loss) + FEC + PLC (high loss) |
| C9 | DTLS fingerprint tampering via signaling | Media | Critical | Server-enforced SDP fingerprint verification |
| C10 | In-call privilege escalation (raw signaling) | Cross-cutting | Critical | Server-side authz on every call control action |
| C11 | Private IP leakage via ICE candidates | Cross-cutting | High | Strip ICE candidates from all UI paths and logs |

---

## Mapping to Existing Framework Threats

| Existing threat | In-call equivalent | Notes |
|-----------------|-------------------|-------|
| Threat 1 — Two Generals' Problem | C2 — missed signaling on disconnect | Seq-num queue replaces idempotency key |
| Threat 3 — Information disclosure | C4, C11 — SDP/ICE/WS leaks | Same mitigation principle, different error surface |
| Threat 6 — Client-side as false gate | C10 — in-call privilege escalation | Server-side authz per call action |
| Threat 7 — Stale auth token | C3 — token expiry mid-call | Proactive refresh required, not just reactive |
| Threat 9 — Half-open circuit breaker | C1 — WS reconnect FSM | Same backoff schedule, FSM adapted for persistent session |
| *(new)* | C5 — ICE restart | No HTTP equivalent; unique to WebRTC/UDP |
| *(new)* | C7 — congestion control | No HTTP equivalent; continuous bitrate adaptation |
| *(new)* | C8 — NACK/FEC/PLC | No HTTP equivalent; real-time loss recovery |
| *(new)* | C9 — DTLS tampering | Extends Threat 6 to media encryption layer |

---

## Part 2 — Active Attack Threats (not covered by passive resilience)

The framework above is built for **passive resilience** — it handles network drops, congestion, path failures, and token expiry. It assumes the network is flaky, not hostile. An attacker who deliberately targets the system in-call finds five serious gaps, documented below.

---

### Attack A1 — Signaling flood (WebSocket message bombing)

**The vulnerability:** The signaling message queue has sequence numbers and server-side replay. There is no limit on how many messages a client can send per second. A WebSocket is a persistent connection — there is no HTTP round-trip cost acting as a natural throttle.

**The exploit:** An attacker (or a compromised participant) sends tens of thousands of signaling messages — mute/unmute commands, SDP re-offers, ICE candidate floods — in rapid succession. The server processes each one faithfully. The sequence number queue fills memory. The SFU gets buried in renegotiation requests. Other participants on the same server experience degraded calls or outright crashes. This is Threat 2 (resource exhaustion / button mashing) from the original framework, applied to a persistent socket.

**Mitigation — per-connection server-side rate limiter:**

```js
const rateLimiter = new Map()  // sessionId → { count, windowStart }

wsServer.on('message', (socket, raw) => {
  const msg = JSON.parse(raw)
  const key = msg.sessionId
  const now = Date.now()
  const state = rateLimiter.get(key) ?? { count: 0, windowStart: now }

  if (now - state.windowStart > 1000) {
    state.count = 1
    state.windowStart = now
  } else {
    state.count++
  }

  rateLimiter.set(key, state)

  if (state.count > 30) {
    // 30 signaling messages/second per participant is already high for legitimate use
    socket.close(4029, 'Rate limit exceeded')
    return
  }

  handleMessage(msg)
})
```

Threshold guidance: a normal participant generates 1–5 signaling messages per second at peak (join, mute, layout change). 30/s is a generous ceiling that blocks floods without affecting legitimate use.

---

### Attack A2 — ICE restart loop (forced reconnect amplification)

**The vulnerability:** The in-call framework triggers an ICE restart automatically when RTCP silence exceeds 2 seconds. There is no rate limit or maximum on how many ICE restarts can be triggered per session.

**The exploit:** An attacker on a shared network (Wi-Fi, corporate LAN) can suppress RTCP packets in 2-second bursts on a repeating cycle. Every burst triggers an ICE restart — a new SDP offer/answer exchange, new ICE candidate gathering, new STUN/TURN probes. At 3-second intervals, the STUN/TURN servers experience a sustained amplification DoS, and the victim's call never stabilizes because each restart takes 2–3 seconds during which media is paused.

**Mitigation — restart cooldown and maximum restart count:**

```js
let iceRestartCount = 0
let lastIceRestart = 0
const ICE_RESTART_COOLDOWN_MS = 10_000  // minimum 10s between restarts
const ICE_RESTART_MAX = 5               // give up after 5 failed restarts

function triggerIceRestart() {
  const now = Date.now()

  if (now - lastIceRestart < ICE_RESTART_COOLDOWN_MS) {
    // Cooldown not elapsed — ignore this trigger
    return
  }

  if (iceRestartCount >= ICE_RESTART_MAX) {
    // Call cannot be recovered — end it gracefully rather than loop forever
    endCallGracefully('Connection could not be restored. Please rejoin.')
    return
  }

  lastIceRestart = now
  iceRestartCount++

  performIceRestart()
}

// Reset counter on successful recovery
peerConnection.addEventListener('iceconnectionstatechange', () => {
  if (peerConnection.iceConnectionState === 'connected') {
    iceRestartCount = 0
  }
})
```

---

### Attack A3 — TURN credential harvesting and relay abuse

**The vulnerability:** The framework embeds TURN credentials in the ICE server configuration delivered to the client. In a web app, this configuration is accessible via DevTools. In an Electron/desktop app, it is accessible by inspecting the JavaScript bundle.

**The exploit:** Any participant can extract the static TURN credentials and use them to relay arbitrary TCP/UDP traffic through your TURN server indefinitely — including after the call ends, after their account is banned, and across calls they were never part of. TURN bandwidth is billed by the byte. A harvested static credential is an open-ended financial attack.

**Mitigation — ephemeral TURN credentials via TURN REST API standard:**

```js
// Server: generate short-lived TURN credentials at call join time
// NEVER embed static credentials in client-side code or the ICE config object

function generateEphemeralTurnCredentials(sessionId) {
  const ttl = 300  // 5 minutes — expires when the call should be over
  const timestamp = Math.floor(Date.now() / 1000) + ttl
  const username = `${timestamp}:${sessionId}`
  const credential = crypto
    .createHmac('sha1', process.env.TURN_SHARED_SECRET)
    .update(username)
    .digest('base64')

  return {
    urls: [
      'turn:turn.example.com:3478?transport=udp',
      'turns:turn.example.com:443?transport=tcp'
    ],
    username,
    credential,
    // Client-side: these credentials auto-expire — no long-term value if stolen
  }
}

// Deliver credentials at call join, not at app load
router.post('/api/v1/call/:sessionId/join', authenticate, async (req, res) => {
  const turnCreds = generateEphemeralTurnCredentials(req.params.sessionId)
  res.json({ turnCredentials: turnCreds, /* ...other join data */ })
})
```

A stolen 5-minute credential expires before an attacker can do meaningful damage. Rotate the `TURN_SHARED_SECRET` on a regular schedule (e.g., weekly) to invalidate any credentials issued from a previous secret.

---

### Attack A4 — SDP injection (call hijacking via crafted offer)

**The vulnerability:** The framework says the signaling WebSocket must be authenticated. It does not specify what validation the server applies to SDP content before forwarding it to other participants.

**The exploit:** An authenticated but malicious participant sends a crafted SDP offer containing a manipulated DTLS fingerprint pointing to an attacker-controlled certificate, or a media `connection` address that redirects another participant's media stream. If the server forwards SDP without validation, the attacker can perform a man-in-the-middle on the victim's media stream — decrypting audio and video despite DTLS-SRTP — or redirect streams to an external recording endpoint.

**Mitigation — server-side SDP validation before forwarding:**

```js
function validateSdpBeforeForwarding(sdp, senderSession) {
  // Rule 1: DTLS fingerprint must match what the sender registered at call join
  // The sender's certificate fingerprint is captured during the initial handshake
  // and stored server-side — it cannot be changed mid-call without a new join
  const declaredFingerprint = extractDtlsFingerprint(sdp)
  if (declaredFingerprint !== senderSession.registeredDtlsFingerprint) {
    throw new SecurityError('SDP fingerprint mismatch — possible injection attempt')
  }

  // Rule 2: Media direction must be sendrecv or sendonly
  // recvonly pointed at an arbitrary address is a stream redirection attempt
  const directions = extractMediaDirections(sdp)
  for (const dir of directions) {
    if (!['sendrecv', 'sendonly', 'inactive'].includes(dir)) {
      throw new SecurityError(`Unexpected media direction: ${dir}`)
    }
  }

  // Rule 3: Connection address in SDP must be localhost or absent
  // Real addresses are negotiated via ICE — a connection address in SDP body is suspicious
  const connectionAddress = extractConnectionAddress(sdp)
  if (connectionAddress && !isLoopbackOrUnspecified(connectionAddress)) {
    throw new SecurityError('Non-loopback connection address in SDP body')
  }
}

// Apply before any SDP is forwarded to another participant
router.post('/api/v1/call/:sessionId/sdp-offer', authenticate, async (req, res) => {
  const senderSession = await getSession(req.params.sessionId, req.user.sub)
  validateSdpBeforeForwarding(req.body.sdp, senderSession)  // throws on violation
  await forwardSdpToParticipants(req.params.sessionId, req.body.sdp)
  res.json({ ok: true })
})
```

---

### Attack A5 — Sequence number replay attack on reconnect

**The vulnerability:** The reconnect FSM replays buffered messages by accepting `lastAckedSeq` from the reconnecting client and replaying everything after that sequence number. There is no expiry on the replay window and no re-verification that the reconnecting peer is the original session owner.

**The exploit:** An attacker who observes a session ID and sequence number (on an unencrypted network segment, or via a compromised participant device) reconnects with the stolen session ID and sends `lastAckedSeq: 0`. The server replays the full call history — every mute event, every participant join/leave, every layout change — to the attacker's socket. In calls with sensitive content (board meetings, interviews, medical consultations), this leaks the entire control transcript.

**Mitigation — time-bounded replay window and mandatory re-authentication on reconnect:**

```js
const REPLAY_WINDOW_MS = 30_000  // only replay messages from the last 30 seconds

wsServer.on('reconnect', async (socket, { sessionId, lastAckedSeq, authToken }) => {

  // Step 1: Re-authenticate — session ID alone is NOT sufficient
  // The fresh authToken proves the reconnector is the same identity as the original joiner
  const claims = await verifyJwt(authToken)
  const session = await getSession(sessionId)

  if (!session || claims.sub !== session.ownerUserId) {
    socket.close(4001, 'Unauthorized reconnect attempt')
    auditLog.warn('Reconnect auth failure', { sessionId, claimsSub: claims.sub })
    return
  }

  // Step 2: Bounded replay — do not replay messages older than the window
  const cutoff = Date.now() - REPLAY_WINDOW_MS
  const missed = session.messageQueue.filter(
    m => m.seq > lastAckedSeq && m.timestamp >= cutoff
  )

  missed.forEach(m => socket.send(JSON.stringify(m)))
})
```

The 30-second window is generous for legitimate reconnects (a Wi-Fi handoff completes in under 5 seconds) but prevents historical replay of the full call.

---

## Updated Complete Threat & Mitigation Matrix

### Passive resilience threats (original)

| # | Threat | Plane | Severity | Mitigation |
|---|--------|-------|----------|------------|
| C1 | WS disconnect — silent call freeze | Signaling | Critical | Heartbeat ping/pong + reconnect FSM |
| C2 | Missed signaling messages during disconnect | Signaling | Critical | Seq-num queue + server-side replay |
| C3 | Auth token expiry mid-call | Signaling | High | Proactive refresh at 80% TTL |
| C4 | SDP/ICE candidate info disclosure | Signaling | High | Sanitized error mapper for WS close codes |
| C5 | NAT timeout / path failure mid-call | WebRTC/UDP | Critical | Auto ICE restart on RTCP silence >2 s |
| C6 | Firewall blocks UDP entirely | WebRTC/UDP | High | TURN TCP/TLS on port 443 fallback |
| C7 | Network congestion → frozen video | WebRTC/UDP | High | GCC + REMB + adaptive bitrate cascade |
| C8 | Packet loss → audio/video glitches | Media | High | NACK (low loss) + FEC + PLC (high loss) |
| C9 | DTLS fingerprint tampering via signaling | Media | Critical | Server-enforced SDP fingerprint verification |
| C10 | In-call privilege escalation (raw signaling) | Cross-cutting | Critical | Server-side authz on every call control action |
| C11 | Private IP leakage via ICE candidates | Cross-cutting | High | Strip ICE candidates from all UI paths and logs |

### Active attack threats (new — Part 2)

| # | Threat | Plane | Severity | Gap | Mitigation |
|---|--------|-------|----------|-----|------------|
| A1 | Signaling flood — WS message bombing | Signaling | Critical | No rate limit on WS messages | Per-connection rate limiter (30 msg/s, drop + close on exceed) |
| A2 | ICE restart loop — RTCP suppression attack | WebRTC/UDP | High | No restart rate cap | 10 s cooldown between restarts, max 5 restarts then graceful end |
| A3 | TURN credential harvesting — relay abuse | WebRTC/UDP | High | Static credentials in client | Ephemeral credentials via TURN REST API, 5-min TTL per session |
| A4 | SDP injection — call hijacking | Media | Critical | No server-side SDP validation | Validate fingerprint, media direction, connection address before forwarding |
| A5 | Seq replay attack — stolen session ID | Signaling | High | Unbounded replay window, no reconnect re-auth | 30 s replay window + mandatory JWT re-authentication on every reconnect |