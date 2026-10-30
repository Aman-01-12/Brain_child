# Cloud LiveKit + Two-Device Testing

Three independent switches. You can flip any one alone.

| Switch | What it changes | Where |
|---|---|---|
| **A. Cloud LiveKit** | Which media server carries audio/video | `token-server/.env` |
| **B. Non-localhost token server** | Which backend the macOS app talks to | `defaults write` on each device |
| **C. LAN-local LiveKit** | Keeps media on the local network instead of the internet | `token-server/.env` + `livekit-server` flags |

For two-device testing you always need **B** (otherwise the second device cannot reach the backend at all), plus **either A or C** for media.

## Which one do I want?

**Are both devices on the same network** — same Wi-Fi, or both on one phone hotspot?

- **Yes → use C (LAN-local LiveKit) + B.** Media stays on the local network: no internet round trip, lower latency, and **no mobile data burned on video** if that network is a phone hotspot. Cloud LiveKit is not needed and is actively worse here (see the warning in section C).
- **No**, the devices are on different networks → **use A (cloud LiveKit) + B.** Also consider a tunnel for the token server (section B, "Tunnelling instead of a LAN IP"), since the second device cannot reach a private LAN address either.
- **Same network, but the second device cannot reach the host** (`curl` to the host's LAN IP times out) → the network has **client isolation**. Many guest and public networks enforce this. Fall back to **A + a tunnel**, because a LAN-local LiveKit would be unreachable for the same reason.

The 30-second test that decides it, once both devices are on the network:

```sh
# host Mac
cd token-server && node index.js

# second device
curl http://<HOST_IP>:3000/health
```

Healthy JSON → go with C. Hang or `Connection refused` → client isolation (or firewall / wrong IP), so re-check those first, then fall back to A + tunnel.

---

## A. Switch to cloud LiveKit

Paste four values into **`token-server/.env`** and restart the token server. Nothing else changes — no client rebuild.

```sh
LIVEKIT_API_KEY=API************
LIVEKIT_API_SECRET=****************************************
LIVEKIT_SERVER_URL=wss://<your-project>.livekit.cloud
LIVEKIT_HTTP_URL=https://<your-project>.livekit.cloud
```

Get these from the LiveKit Cloud dashboard → your project → **Settings → Keys**. The project gives you one `wss://` URL; `LIVEKIT_HTTP_URL` is the **same host over `https://`**. Set both explicitly — the server does not derive one from the other.

Restart:

```sh
cd token-server && node index.js
```

Startup now prints the resolved endpoints. Confirm they are your cloud URLs, not localhost:

```
[token-server] LiveKit WS (handed to clients): wss://<your-project>.livekit.cloud
[token-server] LiveKit HTTP (server-side admin/egress): https://<your-project>.livekit.cloud
```

If you see a `WARNING: LIVEKIT_SERVER_URL / LIVEKIT_HTTP_URL not set`, the key name in `.env` is misspelled and the server fell back to local dev defaults.

**Why one place is enough:** the macOS app never hardcodes a LiveKit URL. It connects to the `serverURL` the token server returns from `/room/create`, `/room/join`, `/meetings/:id/start` and the lobby admission poll. `InterLiveKitServerURL` in `inter/Info.plist` is only a pre-connect placeholder.

Reference template with both configurations side by side: `token-server/.env.example`.

---

## B. Point the macOS app at a non-localhost token server

The packaged default is `http://localhost:3000` (`InterTokenServerURL` in `inter/Info.plist`). Override it at runtime — **no Xcode edit, no rebuild**.

Resolution order, highest first:

1. **Environment variable** `INTER_TOKEN_URL` — for Xcode scheme runs or a terminal launch.
2. **UserDefaults** `InterTokenServerURLOverride` — persists across launches. Bundle id is **`Secure.inter`**.
3. **`inter/Info.plist`** key `InterTokenServerURL` — the packaged default.
4. Built-in fallback `http://localhost:3000`.

With none of 1–3 set, behaviour is exactly as it is today.

### On the second device

```sh
defaults write Secure.inter InterTokenServerURLOverride "http://192.168.1.5:3000"
```

Replace `192.168.1.5` with the **host Mac's** LAN IP (see below). Then launch the app and check the log line:

```
Config: tokenServer=http://192.168.1.5:3000 liveKitPlaceholder=ws://localhost:7880
```

To undo:

```sh
defaults delete Secure.inter InterTokenServerURLOverride
```

One-off run without persisting:

```sh
INTER_TOKEN_URL="http://192.168.1.5:3000" open -n /path/to/inter.app
```

### Find the host Mac's LAN IP

```sh
ipconfig getifaddr en0     # Wi-Fi
ipconfig getifaddr en1     # Ethernet / Thunderbolt adapter, if en0 is empty
```

Both devices must be on the same network. Guest networks and "client isolation" on the router will block device-to-device traffic.

### macOS firewall

The host Mac must accept inbound connections on port 3000. If **System Settings → Network → Firewall** is on, either allow incoming connections for `node`, or turn the firewall off for the duration of the test. Nothing needs to be opened on the second device — it only makes outbound connections.

### macOS 15 local-network permission

On first LAN connection, macOS 15 asks the second device's app for **Local Network** access. Allow it. If the prompt was dismissed, re-enable under **System Settings → Privacy & Security → Local Network**. Without it, LAN requests fail even though the URL is correct.

### Tunnelling instead of a LAN IP

If the two devices are on different networks, or the shared network enforces client
isolation, expose the token server through a tunnel and use the public URL as the
override. `ngrok` is already installed:

```sh
# host Mac
ngrok http 3000          # prints e.g. https://abc123.ngrok-free.app

# second device
defaults write Secure.inter InterTokenServerURLOverride "https://abc123.ngrok-free.app"
```

This needs no server change: there is no CORS or Host-header validation that would
reject the tunnel hostname, and `SERVER_BASE_URL` is only used to build OAuth callback
URLs (irrelevant unless you are demoing OAuth sign-in). Certificate pinning is not a
problem either — `pinnedSPKIHashes` is empty, so the client uses default system trust
and the tunnel's valid certificate is accepted.

A tunnel has one genuine advantage over a LAN IP: it is **HTTPS**, so bearer tokens are
not sent in cleartext.

Two caveats:

- **The free ngrok URL changes on every restart**, so the `defaults write` has to be
  redone each session.
- **`trust proxy` is not set** on the Express app, so behind a tunnel every request
  appears to originate from the same address and IP-keyed rate limits are shared rather
  than per-client. Harmless for a two-person demo; worth knowing if you script
  many requests.

A tunnel only covers the token server. Media still needs A or C.

---

## C. Keep LiveKit local on the LAN

Use this when **both devices share one network** (including one phone hotspot). Media
never leaves the local network.

> **Why not cloud LiveKit on a phone hotspot?**
> Every stream would travel Mac → mobile data → cloud SFU → mobile data → Mac. With two
> participants each publishing and subscribing, that is roughly four video streams over
> the hotspot. A short call can consume hundreds of megabytes, and the added latency and
> constrained uplink visibly degrade quality. Keeping LiveKit on the LAN avoids all of it.

### The problem with the default dev command

`livekit-server --dev` binds **loopback only**, which you can see in its own startup log:

```
"bindAddresses": ["127.0.0.1", "::1"]
```

So the second device cannot reach it, no matter what URL it is given. Two flags fix that:

```sh
HOST_IP=$(ipconfig getifaddr en0)

livekit-server --dev --bind 0.0.0.0 --node-ip "$HOST_IP"
```

- `--bind 0.0.0.0` listens on every interface instead of just loopback.
- `--node-ip "$HOST_IP"` is the one people miss. LiveKit advertises a node address to
  clients for the WebRTC connection; without this it can advertise `127.0.0.1`, and
  **signalling succeeds while media silently fails** — participants connect but see no
  video. Set it explicitly.

### Point the token server at it

In **`token-server/.env`**, use the host's LAN IP rather than `localhost`, then restart:

```sh
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret
LIVEKIT_SERVER_URL=ws://<HOST_IP>:7880
LIVEKIT_HTTP_URL=http://<HOST_IP>:7880
```

Confirm the startup lines show the LAN IP, not localhost:

```
[token-server] LiveKit WS (handed to clients): ws://<HOST_IP>:7880
[token-server] LiveKit HTTP (server-side admin/egress): http://<HOST_IP>:7880
```

This works for the same reason cloud LiveKit does: the client connects to whatever
`serverURL` the token server hands it.

### Firewall

The host Mac needs inbound access for **both** processes — `node` (port 3000) and
`livekit-server` (7880 TCP, 7881 TCP, 7882+ UDP). macOS prompts on first bind; approve
both. A denied `livekit-server` prompt is another cause of "connects but no video".
WebRTC needs the **UDP** range, so do not open only the TCP ports.

### Phone-hotspot specifics

- iPhone Personal Hotspot hands out addresses in `172.20.10.x` and does permit
  device-to-device traffic. Android varies by vendor — run the reachability test above.
- **The host IP changes whenever the hotspot reconnects**, so `token-server/.env`
  (`LIVEKIT_*`) and the second device's `defaults write` both need updating each
  session. Deriving `HOST_IP` with `ipconfig getifaddr en0` rather than hardcoding it
  keeps this to a copy-paste.
- If re-pasting addresses every session becomes tedious, a mesh VPN such as Tailscale
  gives each machine a stable address — at the cost of installing another tool.

### Switching back to single-machine local dev

Restore `ws://localhost:7880` / `http://localhost:7880` in `.env`, run plain
`livekit-server --dev`, and `defaults delete Secure.inter InterTokenServerURLOverride`
on the second device.

---

## Verification checklist

Run in order. Do not move on from a failing step.

1. **Host Mac — backend up:**
   ```sh
   curl http://localhost:3000/health
   ```
   Expect `{"status":"ok","redis":"connected","postgres":"connected"}`.

2. **Host Mac — correct LiveKit endpoints:** check the two `[token-server] LiveKit …` startup lines.

3. **Second device — backend reachable:** this is the step that actually proves two-device testing will work.
   ```sh
   curl http://192.168.1.5:3000/health
   ```
   Same JSON. A hang or `Connection refused` means firewall, wrong IP, or different network — not an app problem.

4. **Second device — override applied:**
   ```sh
   defaults read Secure.inter InterTokenServerURLOverride
   ```

5. **App:** confirm the startup `Config: tokenServer=…` line shows the LAN IP (or tunnel URL), sign in on both devices, host a call on one, join by room code from the other. Audio and video flowing both ways means the media path works.

   If participants **join successfully but no video appears**, the signalling path is
   fine and the media path is not. On topology C that is almost always either a missing
   `--node-ip` or a blocked `livekit-server` firewall prompt (UDP 7882+) — see section C.

---

## Things that stay the same

- **Changing the media layer changes only the media layer.** Whichever of A or C you pick, Postgres, Redis and the token server still run on the host Mac and must stay running there — both devices call the token server for auth, room codes, tokens, chat, moderation, scheduling and recording. Neither switch moves the backend.
- **`livekit-server` is only needed for C.** Once `LIVEKIT_SERVER_URL` points at the cloud (A) you can stop it. For C it must keep running, with the `--bind` / `--node-ip` flags.
- **Going back to local:** restore the local values in `token-server/.env`, restart, start `livekit-server --dev`.

---

## Before any real production deployment

- **Use HTTPS for the token server.** Cleartext `http://` to a non-loopback host sends bearer tokens unencrypted. `inter/Info.plist` keeps full App Transport Security enforcement for public hosts (`NSAllowsLocalNetworking` exempts only loopback / `.local` / private addresses), so an `https://` endpoint works as-is and a cleartext public endpoint will be refused. Remove `NSAppTransportSecurity` once LAN testing is done.
- **Populate the certificate pins.** `InterPinnedSessionDelegate` in `inter/Networking/InterTokenService.swift` ships an empty pin set and therefore falls back to default system trust — correct for development and for an `https://` cloud endpoint, but pin the production certificate (primary + backup) before shipping. The openssl pipeline to compute each pin is in the comment above `pinnedSPKIHashes`.
- **Replace the `devkey`/`secret` dev credentials.** They are LiveKit's well-known dev placeholders.
