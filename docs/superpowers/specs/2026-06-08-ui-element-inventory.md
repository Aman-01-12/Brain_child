# Inter — Complete UI Element Inventory

**Date:** 2026-06-08  
**Purpose:** Screen-by-screen, element-by-element inventory of every button, text field, dropdown, segmented control, badge, menu item, and interaction in the app. Use this as a design specification checklist when creating Figma screens.

---

## 1. Connection / Setup Screen

*Source: `inter/UI/Views/InterConnectionSetupPanel.m`*

| Element | Label / Placeholder | Action |
|---|---|---|
| Text field | `ws://localhost:7880` — Server URL | Persists to UserDefaults |
| Text field | `http://localhost:3000` — Token Server URL | Persists to UserDefaults |
| Text field | `Your name` — Display Name | Persists to UserDefaults |
| Text field | `e.g. X7K29M` — Room Code | Auto-uppercases, max 6 chars, strips 0/O/1/I/L |
| Status indicator dot | ● | Gray=idle, Yellow=connecting, Green=connected, Red=error |
| Status label | "Not connected" | Updates with connection state |
| Room code display | "Room: XXXXXX" (green monospace) | Hidden until a room is hosted |
| **Button** | **"Host Call"** | → Pre-meeting settings sheet |
| **Button** | **"Host Interview"** | → Connects directly (no pre-meeting); may show orange "PRO" badge |
| **Button** | **"Join with Room Code"** | → Joins using code in field |

**Interactions:**
- Typing in Room Code field → auto-uppercase, 6-char limit, remove confusable characters
- Any field losing focus → saves value to UserDefaults
- Buttons enabled/disabled via `setActionsEnabled:`

---

## 2. Login / Register Screen

*Source: `inter/UI/Views/InterLoginPanel.m`*

| Element | Label / Placeholder | Action |
|---|---|---|
| Title label | "Sign In to Inter" / "Create an Account" | Changes with mode |
| **Button** | **"Continue with Google"** | OAuth → Google |
| **Button** | **"Continue with Microsoft"** | OAuth → Microsoft |
| Text field | `you@example.com` — Email | Email input |
| Secure text field | `Minimum 8 characters` — Password | Hidden by default |
| Plain text field | `Minimum 8 characters` — Password visible | Shown when "Show" is pressed |
| **Button** | **"Show" / "Hide"** | Toggles password visibility |
| Password strength meter | 4 horizontal bars | Weak (red) / Fair (orange) / Strong (green) / Very Strong |
| Strength label | "Weak" / "Fair" / "Strong" / "Very Strong" | Register mode only |
| Text field | `Your name` — Display Name | **Register mode only** |
| Error label | (red text) | Shows validation / server errors |
| **Button** | **"Log In" / "Create Account"** | Submits the form |
| **Button** | **"Create Account" / "Back to Login"** | Toggles between login and register modes |
| Spinner | — | Shown during async network request |

**Password strength scoring:**
- Score 0 (empty): no bars, no label
- Score 1 (< 8 chars): 1 bar red, "Weak"
- Score 2 (any 2 character categories): 2 bars orange, "Fair"
- Score 3 (≥10 chars, ≥3 categories): 3 bars green, "Strong"
- Score 4 (≥12 chars, ≥3 categories): 4 bars system green, "Very Strong"

---

## 3. Pre-Meeting Settings Sheet

*Source: `inter/UI/Views/InterPreMeetingPanel.m` — presented as a sheet over the setup window*

### General
| Element | Label | Notes |
|---|---|---|
| Text field | `Meeting name` | Pre-filled with "{Name}'s Meeting" |

### Participant Controls
| Element | Label | |
|---|---|---|
| Checkbox | "Mute Mic After Joining" | |
| Checkbox | "Turn Off Camera After Joining" | |
| Checkbox | "Allow Unmuting" | |

### Security
| Element | Label | Notes |
|---|---|---|
| Checkbox | "Enable Waiting Room" | |
| Checkbox | "Require Password" | Reveals password field when toggled ON |
| Text field | `Meeting password` | Only visible when password toggle is ON |
| Checkbox | "Join Before Host" | |

### Chat & Sharing
| Element | Label | Dropdown Items |
|---|---|---|
| Dropdown | **Chat Permissions** | "Everyone" / "Host Only" / "Disabled" |
| Dropdown | **Screen Sharing** | "Host Only" / "Everyone" / "Request to Share" |
| Dropdown | **Share Takeover** | "One at a Time" / "Host Can Take Over" / "Anyone Can Take Over" |

### Recording & Transcription *(Pro-gated — disabled for free tier)*
| Element | Label | |
|---|---|---|
| Checkbox | "Auto-Record to Cloud" | |
| Checkbox | "Auto-Transcript" | |
| Checkbox | "Allow Co-Host Local Recording" | |
| Note label | "✦ Requires Pro or Pro+ subscription" (yellow) | Hidden for pro users |

### Action Buttons
| Element | Label | Notes |
|---|---|---|
| **Button** | **"Cancel"** | Dismisses sheet |
| **Button** | **"Start Meeting" (⏎)** | Saves settings, begins call |

---

## 4. In-Call Window

### 4A. Control Bar

*Source: `inter/UI/Views/InterLocalCallControlPanel.m`*

| Element | Label | Action |
|---|---|---|
| **Button** | **"Turn Camera On" / "Turn Camera Off"** | Toggles camera (two-phase) |
| **Button** | **"Turn Mic On" / "Turn Mic Off"** | Toggles microphone (two-phase) |
| **Button** | **"Start Surface Share" / "Stop Surface Share"** | Toggles screen share |
| **Button** | **"Start Recording" / "Stop Recording"** | Toggles recording |
| **Button** | **"📁 Recordings"** | Opens recordings panel |
| Dropdown | **Share Mode** | "Share Window" / "Share Entire Screen" |
| Dropdown | **Audio Input Source** | Populated dynamically from available microphones |
| Segmented (3 segments) | **Interview Tool** | "Off" / "Code" / "Board" — hidden in normal call |
| Segmented (3 segments) | **Screen Share Permission** (host only) | "Everyone" / "Ask" / "Host Only" |
| Checkbox | "Share System Audio" | |
| Network quality bars | ●●●● | 4-level: unknown/poor/good/excellent |
| Status label | "Camera on, Mic on." | Live media status |
| Status label | "Secure surface share is off." | Live share status |
| Room code label | "Room: XXXXXX" (monospace, green) | Hidden until room is hosted |

### 4B. Video Tile Chrome (per remote participant tile)

*Source: `InterRemoteVideoTileView` inside `inter/UI/Views/InterRemoteVideoLayoutManager.m`*

| Element | When visible | Notes |
|---|---|---|
| Name label | Always | Bottom, dark scrim background, truncated |
| ✋ Hand-raise badge | When participant raises hand | Top-left, 24×24px |
| 🔇 Mic-muted badge | When mic track muted | Bottom-right above name |
| 👑 Co-host badge | When co-host status assigned | Top-right, below menu button |
| 🔒 Camera-locked badge | When host locked camera | Bottom-right, next to mic badge |
| Avatar placeholder (initial) | When camera is off | Circular, dark grey, uppercase initial |
| Green border (3px) | When participant is speaking | Active speaker indicator |
| White border (2px) | On hover | Hover highlight |
| **Three-dot menu button** | On hover — host only | Top-right corner, 22×22px |
| Pointing-hand cursor | On hover | Indicates click-to-spotlight |

#### Three-dot Moderation Menu *(host only — opens on button click)*

**For host participant tiles:**
- "Pin for All" / "Unpin for All"
- "Pin for All (max 5 reached)" *(disabled when all pin slots full)*

**For regular participant tiles:**
- "Mute Mic" / "Unmute Mic"
- "Mute Camera" / "Unmute Camera"
- — separator —
- "Pin for All" / "Unpin for All"
- — separator —
- "Make Co-Host" / "Remove Co-Host" *(hidden if local user is co-host, not host)*
- "Rename…"
- — separator —
- **"Remove from Meeting"** *(red text)*

### 4C. Layout Controls

*Source: `inter/UI/Views/InterRemoteVideoLayoutManager.m`*

| Element | Label | Action / Notes |
|---|---|---|
| **Button** | **"Stage" / "Grid"** | Toggles layout mode; hidden when < 2 tiles |
| **Button** | **◀** | Previous page (paginated grid mode, wraps) |
| **Button** | **▶** | Next page (paginated grid mode, wraps) |
| Page label | "Page X of Y" | Centered in page indicator bar |
| Participant count badge | "N" | Top-left corner |

### 4D. Participant Overlay

*Source: `inter/UI/Views/InterParticipantOverlayView.m`*

| State | Visual | Buttons |
|---|---|---|
| Waiting for participants | "Waiting for participants…" + pulsing green dot | — |
| All participants left | "All participants left." | **"Wait"** / **"End Call"** |

### 4E. Recording Indicator *(shown while recording is active)*

*Source: `inter/UI/Views/InterRecordingIndicatorView.m`*

| Element | Description |
|---|---|
| Red pulsing dot | Pulses 1.0→0.2 opacity, 0.8s cycle |
| "REC" / "PAUSED" label | Yellow and static when paused |
| Time display | HH:MM:SS elapsed, monospaced digits |

### 4F. Network Status View

*Source: `inter/UI/Views/InterNetworkStatusView.m`*

| Quality Level | Color | Bars filled |
|---|---|---|
| Unknown | Gray | 0 |
| Lost | Red | 1 |
| Poor | Orange | 2 |
| Good | Yellow-green | 3 |
| Excellent | Green | 4 |

---

## 5. Chat Panel

*Source: `inter/UI/Views/InterChatPanel.m`*

| Element | Label | Notes |
|---|---|---|
| **Button** | **"✕" Close** | Collapses the panel |
| **Button** | **Export** (share icon) | Pro/host only; hidden for free |
| Dropdown | **Recipient selector** | "Everyone" + individual participant names for DM |
| Text field | `Type a message…` / `DM to [name]…` | Message input; disabled when chat is disabled by host |
| **Button** | **"Send"** (or Enter key) | Submits message |
| **Button** | **📎 Attach file** | Opens file picker, max 10 MB |
| Per file message | **"Save…"** | Downloads file to disk |
| Message rows | Sender + time + content | Blue=sent public, purple=DM, gray=system message |

---

## 6. Lobby Panel (Host Side)

*Source: `inter/UI/Views/InterLobbyPanel.m`*

| Element | Label | Notes |
|---|---|---|
| Checkbox | "Enable Waiting Room" | Disabled for co-hosts |
| **Button** | **"Admit All"** | Disabled when queue is empty |
| Per-row **Button** | **"✓" Admit** (green) | Admits single participant |
| Per-row **Button** | **"✕" Deny** (red) | Denies single participant |
| Row content | Name label + elapsed time | "Just now" or "X min ago" |
| Empty state label | "No one is waiting" | Hidden when queue has items |

---

## 7. Lobby Waiting View (Participant Side)

*Source: `inter/UI/Views/InterLobbyWaitingView.m`*

| State | Icon | Title | Message | Button |
|---|---|---|---|---|
| Joining | video.fill (blue) | "Joining Meeting" | "Connecting to the meeting…" | "Cancel" |
| Waiting | person.badge.clock (blue) | "Waiting Room" | "Please wait, the host will let you in shortly." | "Leave" |
| With queue position | same | same | + "Your position in queue: N" | "Leave" |
| Denied | same (red) | "Access Denied" | "The host has denied your request…" | "OK" |
| Admitted | same (green) | "You're In!" | "Admitted. Connecting…" | (hidden) |

Spinner animates during Joining and Waiting states; stops for Denied and Admitted.

---

## 8. Q&A Panel

*Source: `inter/UI/Views/InterQAPanel.m`*

| Element | Label | Notes |
|---|---|---|
| **Button** | **"✕" Close** | Hides the panel |
| Text field | `Ask a question…` | Question input |
| Checkbox | "Anonymous" | Optional; hides asker name |
| **Button** | **"Ask" / Submit** | Submits question |
| Per-question **Button** | **"▲ N" Upvote** | Blue when already upvoted (disabled); gray otherwise |
| Per-question **Button** (host) | **"📌" Highlight** | Blue row tint on highlight |
| Per-question **Button** (host) | **"✅" Mark Answered** | Green row tint on answer |
| Per-question **Button** (host) | **"✕" Dismiss** (red) | Removes question from list |

**Row states:**
- Default: dark background
- Highlighted: blue-tinted background
- Answered: green-tinted background
- Sorted: upvote count descending; highlighted first

---

## 9. Poll Panel

*Source: `inter/UI/Views/InterPollPanel.m`*

### Host — Create Mode
| Element | Label | Notes |
|---|---|---|
| Text field | `Type your question here…` | Poll question (required) |
| Text fields (2–10) | `Option 1`, `Option 2`, … | Answer choices |
| Checkbox | "Anonymous voting" | |
| Checkbox | "Allow multiple selections" | |
| **Button** | **"+ Add Option"** | Disabled at 10 options |
| **Button** | **"Launch Poll"** | Validates and starts poll |

### Host — Active Mode
| **Button** | **"Share Results"** | Broadcasts live results to all |
| **Button** | **"End Poll"** (red) | Closes poll, shows final results |

### Participant — Voting Mode
| Radio / Checkbox (per option) | Option text | Single-select or multi-select |
| **Button** | **"Submit Vote"** (green) | Submits vote |

### All — Results Mode
| Bar per option | Label + count + % | Green if local voted, blue otherwise |
| **Button** (host) | **"New Poll"** | Resets to create mode |

---

## 10. Moderation Queue Panels

### 10A. Speaker Queue Panel

*Source: `inter/UI/Views/InterSpeakerQueuePanel.m`*

| Element | Label | Notes |
|---|---|---|
| Header | "✋ Raised Hands" | |
| **Button** | **"✕" Close** | |
| **Button** | **"Dismiss All"** (red) | Hidden when queue is empty |
| Per-row **Button** | **"Dismiss"** | Always present |
| Per-row **Button** | **"Allow"** (green) | Shown when host has muted all, or participant was individually host-muted |
| Empty state | "No raised hands" | |

### 10B. Screen Share Requests Panel

*Source: `inter/UI/Views/InterScreenShareQueuePanel.m`*

| Element | Label | Notes |
|---|---|---|
| Header | "📺 Share Requests" | |
| **Button** | **"✕" Close** | |
| **Button** | **"Approve All"** (green) | Hidden when queue is empty |
| **Button** | **"Deny All"** (red) | Hidden when queue is empty |
| Per-row **Button** | **"Approve"** (green) | |
| Per-row **Button** | **"Deny"** | |
| Empty state | "No share requests" | |

### 10C. Camera Unlock Requests Panel

*Source: `inter/UI/Views/InterCameraUnlockQueuePanel.m`*

| Element | Label | Notes |
|---|---|---|
| Header | "🔒 Camera Requests" | |
| **Button** | **"✕" Close** | |
| **Button** | **"Approve All"** (green) | Hidden when queue is empty |
| **Button** | **"Deny All"** (red) | Hidden when queue is empty |
| Per-row **Button** | **"Approve"** (green) | |
| Per-row **Button** | **"Deny"** | |
| Empty state | "No camera unlock requests" | |

### 10D. Mic Unlock Requests Panel

*Source: `inter/UI/Views/InterMicUnlockQueuePanel.m`*

| Element | Label | Notes |
|---|---|---|
| Header | "🎙 Mic Requests" | |
| **Button** | **"✕" Close** | |
| **Button** | **"Approve All"** (green) | Hidden when queue is empty |
| **Button** | **"Deny All"** (red) | Hidden when queue is empty |
| Per-row **Button** | **"Approve"** (green) | |
| Per-row **Button** | **"Deny"** | |
| Empty state | "No mic unlock requests" | |

---

## 11. Recording Consent Modal

*Source: `inter/UI/Views/InterRecordingConsentPanel.m`*

| Element | Content | Notes |
|---|---|---|
| Icon | record.circle.fill (red, 32px) | |
| Title | "This Meeting Is Being Recorded" | Bold, 17pt, centered |
| Body text | Consent description | Multi-line, centered |
| Mode label | "Recording type: Local / Cloud / Multi-track" | Updates dynamically |
| **Button** | **"Continue & Accept" (⏎)** | Primary; accepts consent |
| **Button** | **"Leave Meeting"** (red) | Declines; leaves meeting |

Modal backdrop blocks all interaction behind it. Both buttons dismiss the panel after delegating.

---

## 12. Secure Interview Window

*Source: `inter/UI/Controllers/SecureWindowController.m` and interview sub-views*

### 12A. Main Window Controls
| Element | Label | Shortcut | Action |
|---|---|---|---|
| **Button** | **"Exit Session"** | ⌘Q | Confirmation alert, then exits |
| **Button** | **"💬 Chat"** | ⌘⇧C | Toggles floating chat overlay |

### 12B. Control Panel (right sidebar)
Same controls as §4A with these differences:
- **Tool selector (segmented)** "Off" / "Code" / "Board" — **visible here** (hidden in normal calls)
- Share mode dropdown — **hidden** (always "Share This App")
- System Audio toggle — **hidden**
- Share toggle → shares the active tool surface only (not the desktop)

**Share status label states:**
1. "Secure tool share is off. Choose a tool before you begin sharing." *(no tool selected)*
2. "Secure tool share is off. [Tool] selected. Press Share to start publishing it." *(tool ready)*
3. "Secure tool share is active. [Tool] visible to the other participant." *(sharing active)*
4. "Sharing is paused — select a tool to resume." *(sharing, but tool switched away)*

### 12C. Interview Stage — Center Content
Switches between two modes (click a preview card in the right rail to select):
- **Remote video mode** — remote participant fills main workspace
- **Tool mode** — code editor or whiteboard fills main workspace (when share is active)

### 12D. Right Rail (scrollable preview cards)
- One card per remote participant (camera + name label)
- Screen share card (if active)
- Tool preview card — "Code Preview" / "Whiteboard Preview" (if tool active but not in center)
- Click any card → promotes it to center
- Selected card: 2px blue border

### 12E. Code Editor

*Source: `inter/UI/Views/InterSecureCodeEditorView.m`*

| Element | Notes |
|---|---|
| NSTextView | 13pt monospaced system font, white text on dark background |
| Placeholder | "Open the secure editor and type here. Only this editor surface is shared in interview mode." |
| Find bar | ⌃F to open (native NSTextView find bar) |
| Undo/Redo | ⌘Z / ⌘⇧Z |
| **All smart substitutions: OFF** | Smart quotes, autocorrect, autocomplete, spell check — all intentionally disabled |
| Context menu (right-click) | Standard: Cut / Copy / Paste / Delete / Select All / Look Up |

### 12F. Whiteboard

*Source: `inter/UI/Views/InterSecureWhiteboardView.m`*

| Element | Notes |
|---|---|
| Drawing surface | Mouse drag to draw; freehand pen only |
| Pen | 3pt width, round cap/join, white/light gray stroke |
| Grid | Subtle 32pt grid drawn under strokes |
| Clear canvas | Accessible via stage controller (no visible button in the whiteboard view itself) |
| **Currently missing:** | Colors, eraser, undo/redo, shape tools, stroke width control |

### 12G. Chat Overlay (floating panel above the secure window)

*Source: `SecureWindowController.m` — NSPanel at NSScreenSaverWindowLevel + 1*

- Same chat panel as §5 with these restrictions:
  - File sharing **disabled** → shows alert: "File Sharing Unavailable in secure interview mode"
  - File download **disabled** → shows alert: "Cannot download files in secure session"
  - No DM recipient selector (single-channel only)
  - No export button

**Chat button tint states:**
- Light gray (0.8 white) — no unread messages
- System blue — overlay visible
- System orange — unread messages while overlay is hidden

---

## 13. Account Panel

*Source: `inter/UI/Views/InterAccountPanel.m`*

### Profile Section
| Element | Notes |
|---|---|
| Email display | Monospaced, truncates middle |
| Plan tier display | e.g., "Plan: Free" / "Plan: Pro" |

### Change Password
| Element | Label | Notes |
|---|---|---|
| Secure text field | "Current password" | Required |
| Secure text field | "New password (8–72 characters)" | 8–72 char limit |
| Secure text field | "Confirm new password" | Must match new password |
| **Button** | **"Change Password"** | Disables fields, shows spinner during request |
| Status label | (green/red) | Success or error message |

### Change Email
| Element | Label | Notes |
|---|---|---|
| Secure text field | "Confirm your password" | Required |
| Text field | "New email address" | Must contain "@" |
| **Button** | **"Send Verification"** | Disables fields, shows spinner during request |
| Status label | (green/red) | Mentions verification email on success |

### Active Sessions
| Element | Notes |
|---|---|
| **Button** "↻ Refresh" | Fetches session list |
| Sessions table — "Device" column | 8-char truncated clientId |
| Sessions table — "Started" column | Formatted date/time |
| Sessions table — "Last Used" column | Formatted date/time or "Never" |
| Sessions table — "Action" column | **"Revoke"** button, or "This Device" green label |
| Empty state | "No active sessions found." |

### ⚠ Danger Zone
| Element | Notes |
|---|---|
| Description text | "Permanently deletes your account…" |
| **Button** **"Delete Account…"** (red) | → Confirmation alert with NSSecureTextField for password → **"Delete My Account"** (destructive) / **"Cancel"** |

---

## 14. Schedule Panel

*Source: `inter/UI/Views/InterSchedulePanel.m`*

### Calendar (left pane)
| Element | Label | Notes |
|---|---|---|
| **Button** | **"‹"** | Previous month |
| Month/year label | "June 2026" | Centered |
| **Button** | **"›"** | Next month |
| Day grid cells | Day numbers | Click → selects date, reveals form |

**Day cell visual states:**
- Today: dark gray circle background
- Selected: blue circle background + blue dot below
- Has meeting: small blue dot below number
- Past/other-month: grayed-out text

### New Meeting Form (right pane, revealed on date click)
| Element | Label | Notes |
|---|---|---|
| **Button** | **"✕"** | Closes form |
| Time picker | Hours/minutes | NSDatePicker |
| Text field | `e.g. Sprint Planning` | Meeting title — required |
| Dropdown | **Duration** | 15 / 20 / 30 / 45 / 60 / 90 / 120 min |
| Dropdown | **Room Type** | "Call" / "Interview" |
| Text field | `Leave blank for none` | Password — optional |
| Text field | `alice@example.com, bob@example.com` | Invite emails (comma-separated) — optional |
| Checkbox | "Enable lobby (waiting room)" | Optional |
| **Button** | **"Schedule Meeting"** | Validates, submits |
| Status label | — | "Scheduling…" / success green / error red |

### Upcoming Meetings
| Element | Notes |
|---|---|
| Segmented control | "Hosted" / "Invited" — filters the list |
| Meetings table rows | Title + date + duration + invitee count |
| Per-row **Button** | **"Join"** — only shown if roomCode is available |
| Per-row **Button** | **"Cancel"** — hosted meetings only |

---

## 15. Teams Panel

*Source: `inter/UI/Views/InterTeamsPanel.m`*

### Toolbar
| **Button** | **"↻ Refresh"** | Reloads teams list |
| Spinner | Adjacent to Refresh | Visible during fetch |

### Sidebar — Teams List
| Element | Notes |
|---|---|
| Teams table | Name + role badge ("Invited"/"Owner"/"Admin") |
| Click row | Loads team detail |

### Sidebar — Create Team Form
| Text field | `Team name` | Required |
| Text field | `Description (optional)` | |
| **Button** | **"Create"** | Validates name, creates team |

### Detail Area
| Element | Notes |
|---|---|
| Team name title | 16pt bold |
| Team description | Secondary text |
| **Button** **"Accept Invitation"** | Visible only if caller's status = "pending" |
| **Button** **"Delete Team"** (red, owner only) | Confirmation alert, then deletes |

### Members Table
| Element | Notes |
|---|---|
| Columns | Name (bold) + Email + "Role · Status" |
| Per-row **"Remove"** button | Owner/admin only; not shown for owner row |

### Invite Section
| Text field | `Invite by email (comma-separated)` | |
| **Button** | **"Invite"** | Parses emails, sends invitations |

---

## 16. Recording List Panel

*Source: `inter/UI/Views/InterRecordingListPanel.m`*

| Element | Notes |
|---|---|
| **Button** "↻ Refresh" | Rescans local files + fetches cloud |
| **Button** "✕" Close | |
| Section header | "Local Recordings (N)" |
| Section header | "Cloud Recordings (N)" |
| Recording row | Title + badge (LOCAL/CLOUD/MULTI/FAILED) + date + duration + size |
| Per-row **Button** "Open" (local) | Opens local .mp4 file |
| Per-row **Button** "Download" (cloud/multi) | Downloads recording |
| Per-row **Button** "✕" Delete (red) | Deletes recording |
| Empty state | "No recordings yet." |

**Badges by type:**
- LOCAL → blue
- CLOUD → green
- MULTI → purple
- FAILED → red

---

## 17. Window Picker Sheet

*Source: `inter/UI/Views/InterWindowPickerPanel.m`*

| Element | Notes |
|---|---|
| Header label | "Choose a window to share" — 18pt semibold |
| Window tile grid | 3 columns, 184pt per tile |
| Tile content | Screenshot thumbnail + app icon (20×20) + window title + subtitle |
| Tile states | Default (dark bg) / Hovered (light border) / Selected (blue 3px border) |
| Loading spinner | Shown while enumerating windows and capturing thumbnails |
| Empty state | "No windows available to share." |
| **Button** | **"Cancel"** | Dismisses without sharing |
| **Button** | **"Share" (⏎, blue)** | Disabled until a tile is selected; starts screen capture |

---

## Quick-Reference Matrix

| Screen | Key controls summary |
|---|---|
| **Connection Setup** | 4 text fields, 3 action buttons, status dot |
| **Login / Register** | Email + password + display name, show/hide, strength meter, OAuth buttons, mode toggle |
| **Pre-Meeting** | 6 checkboxes, 3 dropdowns, 2 text fields (name + optional password) |
| **In-Call Controls** | 5 buttons, 2 dropdowns, 2 segmented controls, 1 checkbox |
| **Video Tile Chrome** | Name label, 4 emoji badges → SF Symbols to replace, 3-dot menu (9 items), avatar, hover border |
| **Layout Controls** | Stage/Grid toggle, ◀▶ pagination, page label |
| **Chat** | Recipient dropdown, text input, send, attach, per-message download |
| **Lobby (host)** | Enable checkbox, Admit All, per-row Admit/Deny |
| **Lobby (waiting)** | State-driven: icon + title + message + spinner + single action button |
| **Q&A** | Question input, anonymous toggle, per-row upvote/highlight/answer/dismiss |
| **Poll** | Question + option fields, toggles, Launch; then vote or results bars |
| **Speaker Queue** | Dismiss All, per-row Dismiss / Allow |
| **Share Requests** | Approve All + Deny All, per-row Approve / Deny |
| **Camera Requests** | Approve All + Deny All, per-row Approve / Deny |
| **Mic Requests** | Approve All + Deny All, per-row Approve / Deny |
| **Recording Consent** | Mode label, Continue & Accept / Leave Meeting |
| **Secure window** | Exit, Chat toggle, tool selector (Off/Code/Board), share toggle, code editor, whiteboard |
| **Account** | 3 password fields, 2 email fields, sessions table with Revoke, Delete Account |
| **Schedule** | Calendar grid, 7-field meeting form, meetings table with Join/Cancel |
| **Teams** | Create form (2 fields), invite field, members table, Delete Team |
| **Recording List** | Section headers, per-row Open/Download/Delete |
| **Window Picker** | Thumbnail tile grid, Cancel / Share |

---

## Design Notes for Figma

1. **Tile badge replacements (priority):** The four emoji badges (✋ 🔇 👑 🔒) and the `"···"` menu button should become SF Symbols in the design. Equivalents: `hand.raised.fill`, `mic.slash.fill`, `crown.fill`, `lock.fill`, `ellipsis.circle.fill`.

2. **Role-based states:** Several screens show different controls for Host vs Co-host vs Guest. Design each screen in at least two variants where this applies (Chat, Lobby, Q&A, Poll, tile moderation menu).

3. **Loading / async states:** Account, Schedule, Teams, and Recording panels all have loading spinners and disabled states. Design these states too.

4. **Empty states:** Every list/table has an empty state label. Include these in designs.

5. **Pro-gating:** Pre-Meeting recording toggles are disabled for free users. Design the disabled state with the yellow "✦ Requires Pro or Pro+" note visible.

6. **Secure interview mode:** Several controls that exist in normal calls are **hidden** in the secure window (share mode dropdown, system audio toggle, the tile three-dot menu). The tool selector and a different share status label replace them.

7. **Shared design tokens:** Colors, corner radii, font sizes, and SF Symbol names defined once in the design system should feed both the AppKit tile chrome and all SwiftUI panels to prevent visual drift.
