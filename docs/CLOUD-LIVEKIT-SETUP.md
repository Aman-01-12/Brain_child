# Cloud LiveKit + Two-Device Testing

Two independent switches. You can flip either one alone.

| Switch | What it changes | Where |
|---|---|---|
| **A. Cloud LiveKit** | Which media server carries audio/video | `token-server/.env` |
| **B. Non-localhost token server** | Which backend the macOS app talks to | `defaults write` on each device |

For two-device testing you need **both**: cloud LiveKit (or a LAN-reachable local LiveKit) for media, and B so the second device can reach the backend at all.

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

5. **App:** confirm the startup `Config: tokenServer=…` line shows the LAN IP, sign in on both devices, host a call on one, join by room code from the other. Audio and video both ways means the cloud media path works.

---

## Things that stay the same

- **Cloud LiveKit replaces only the media layer.** Postgres, Redis and the token server still run on the host Mac, and the token server must stay running there — both devices call it for auth, room codes, tokens, chat, moderation, scheduling and recording.
- **`livekit-server --dev` is no longer needed** once `LIVEKIT_SERVER_URL` points at the cloud. You can stop it. (Keep running it if you switch back to local URLs.)
- **Going back to local:** restore the local values in `token-server/.env`, restart, start `livekit-server --dev`.

---

## Before any real production deployment

- **Use HTTPS for the token server.** Cleartext `http://` to a non-loopback host sends bearer tokens unencrypted. `inter/Info.plist` keeps full App Transport Security enforcement for public hosts (`NSAllowsLocalNetworking` exempts only loopback / `.local` / private addresses), so an `https://` endpoint works as-is and a cleartext public endpoint will be refused. Remove `NSAppTransportSecurity` once LAN testing is done.
- **Populate the certificate pins.** `InterPinnedSessionDelegate` in `inter/Networking/InterTokenService.swift` ships an empty pin set and therefore falls back to default system trust — correct for development and for an `https://` cloud endpoint, but pin the production certificate (primary + backup) before shipping. The openssl pipeline to compute each pin is in the comment above `pinnedSPKIHashes`.
- **Replace the `devkey`/`secret` dev credentials.** They are LiveKit's well-known dev placeholders.
