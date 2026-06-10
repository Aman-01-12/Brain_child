import React from "react";
import { ConnectionSetupMock } from "../components/mocks/ConnectionSetupMock";
import { LoginRegisterMock } from "../components/mocks/LoginRegisterMock";
import { InCallMock } from "../components/mocks/InCallMock";
import { HostInMeetingMock } from "../components/mocks/HostInMeetingMock";
import { ChatMock } from "../components/mocks/ChatMock";
import { ScheduleMock } from "../components/mocks/ScheduleMock";
import { PreMeetingMock } from "../components/mocks/PreMeetingMock";
import { GreenRoomMock } from "../components/mocks/GreenRoomMock";
import { AccountPanelMock } from "../components/mocks/AccountPanelMock";
import { LobbyMock } from "../components/mocks/LobbyMock";
import { QAMock } from "../components/mocks/QAMock";
import { PollMock } from "../components/mocks/PollMock";
import { TeamsMock } from "../components/mocks/TeamsMock";
import { SecureInterviewMock } from "../components/mocks/SecureInterviewMock";
import { SecureInterviewCandidateMock } from "../components/mocks/SecureInterviewCandidateMock";

export type ScreenData = {
  id: string;
  title: string;
  description: string;
  category: "Core Flows" | "Access" | "Live Session" | "Collaboration" | "Management" | "Security";
  fidelity: "Hi-Fi";
  source: string;
  mockComponent?: React.FC;
  markdownSpec: string;
};

export const screens: Record<string, ScreenData> = {
  "connection": {
    id: "connection",
    title: "Home / Launch Screen",
    description: "Main landing window users see on app open — identity, primary actions, and recent meetings.",
    category: "Core Flows",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterConnectionSetupPanel.m",
    mockComponent: ConnectionSetupMock,
    markdownSpec: `> **Note:** Server URL and Token Server URL fields exist only in the development build
> for pointing at a local LiveKit instance. In the production app this is a home screen.

### Primary Actions (Zoom-style grid)
| Button | Action |
|---|---|
| **New Meeting** | Starts a hosted call immediately |
| **Join** | Opens join-by-code flow |
| **Schedule** | Opens calendar / schedule sheet |
| **Share** | Starts a screen-share-only session |

### Identity Strip
| Element | Notes |
|---|---|
| Avatar + name | Pulled from account profile |
| Personal Meeting ID | Monospace, tap to copy |
| Presence dot | Online / Away / Do Not Disturb |

### Join via Room Code
| Element | Label / Placeholder | Action |
|---|---|---|
| Text field | \`e.g. X7K29M\` | Auto-uppercases, 6-char max, strips confusable chars |
| **Button** | **"Join"** | Connects to the room |

### Recent Meetings
| Element | Notes |
|---|---|
| Meeting row | Title, timestamp, participant count |
| Copy icon | Copies room code to clipboard |
| **Button** | **"Start"** — re-launches the same room |

### Dev-only fields (hidden in production)
| Field | Purpose |
|---|---|
| WebSocket URL | Points at local LiveKit server |
| Token Server URL | Points at local token generator |`
  },
  "auth": {
    id: "auth",
    title: "Login / Register Screen",
    description: "Authentication with OAuth and email/password options.",
    category: "Access",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterLoginPanel.m",
    mockComponent: LoginRegisterMock,
    markdownSpec: `| Element | Label / Placeholder | Action |
|---|---|---|
| Title label | "Sign In to Inter" / "Create an Account" | Changes with mode |
| **Button** | **"Continue with Google"** | OAuth → Google |
| **Button** | **"Continue with Microsoft"** | OAuth → Microsoft |
| Text field | \`you@example.com\` — Email | Email input |
| Secure text field | \`Minimum 8 characters\` — Password | Hidden by default |
| Password strength meter | 4 horizontal bars | Weak / Fair / Strong / Very Strong |
| **Button** | **"Log In" / "Create Account"** | Submits the form |`
  },
  "account": {
    id: "account",
    title: "Account & Settings Panel",
    description: "Full settings panel — profile, password, email, active sessions, meeting defaults, devices, and security.",
    category: "Access",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterAccountPanel.m",
    mockComponent: AccountPanelMock,
    markdownSpec: `### Account group
| Tab | Elements |
|---|---|
| **Profile** | Avatar, display name (editable), email (monospace), plan tier badge, 2FA badge, Timezone dropdown, Language dropdown, Personal Meeting ID + copy link |
| **Password** | Current password field, New password field (8–72 chars), Confirm field, Change Password button, status label |
| **Email** | Current password confirm, New email field, Send Verification button, status label |
| **Sessions** | Refresh button, table: Device (8-char ID) / Started / Last Used / Revoke or "This Device"; Danger Zone — Delete Account |

### Meetings group
| Tab | Elements |
|---|---|
| **Meeting Defaults** | All pre-meeting settings stored as user defaults — mute/camera/unmute controls, waiting room, password, join-before-host, chat/share/takeover dropdowns, pro-gated recording toggles + amber callout |
| **Video** | Camera dropdown, preview canvas, show-preview toggle, stop-on-join toggle, touch-up toggle, low-light toggle, mirror toggle |
| **Audio** | Speaker dropdown + Test link, Mic dropdown + Test link, auto-join toggle, mute-on-join toggle, noise suppression toggle |
| **Background** | 4 background presets (None / Blur / Office / Nature) |
| **Security** | 2FA toggle, sign-out-on-pw-change toggle, recordings-to-verified toggle |

> **Note:** "Account Panel" and "Settings Panel" are the same screen in the catalogue — the inventory calls it InterAccountPanel.m.`
  },
  "in-call": {
    id: "in-call",
    title: "In-Call Window",
    description: "Main video conferencing window with tile grid and controls.",
    category: "Live Session",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterLocalCallControlPanel.m",
    mockComponent: InCallMock,
    markdownSpec: `### Control Bar — UX Hierarchy (Zoom / Teams pattern)
Controls are grouped by frequency of use and criticality, with labeled icons for instant recognition.

**Primary zone (left) — critical, highest frequency**
| Control | Label | Action |
|---|---|---|
| Mic | "Mute / Unmute" | Toggles microphone; chevron opens audio-device menu |
| Camera | "Start / Stop Video" | Toggles camera; chevron opens video-device menu |

**Secondary zone (center) — grouped session actions**
| Control | Label | Action |
|---|---|---|
| Participants | "Participants" (count badge) | Opens roster |
| Chat | "Chat" (unread badge) | Opens chat panel |
| Share | "Share / Stop Share" | Toggles screen share |
| React | "React" | Opens reactions tray |
| Raise Hand | "Raise Hand" | Toggles hand raise |
| More | "More" | Overflow menu for low-frequency actions |

**Destructive zone (right) — isolated**
| Control | Label | Action |
|---|---|---|
| Leave | "Leave" (red) | Exits the call; spatially separated to prevent mis-taps |

### Video Tile Chrome
| Element | Notes |
|---|---|
| Name label | Bottom-left over a dark scrim |
| Mic state | Bottom-right; red when muted |
| ✋ Raise-hand badge | Top-left, high-visibility amber |
| Co-host tag | Top-right |
| Active speaker | Emerald ring around the tile |`
  },
  "pre-meeting": {
    id: "pre-meeting",
    title: "Pre-Meeting Settings Sheet",
    description: "Host settings sheet before starting a meeting — participant controls, security, sharing, and recording.",
    category: "Core Flows",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterPreMeetingPanel.m",
    mockComponent: PreMeetingMock,
    markdownSpec: `*Shown as a sheet when the host taps "New Meeting". Configures the session before it starts.*

### General
| Element | Notes |
|---|---|
| Text field — Meeting name | Pre-filled with "{Name}'s Meeting" |

### Participant Controls
| Checkbox | Notes |
|---|---|
| Mute mic after joining | |
| Turn off camera after joining | |
| Allow unmuting | Participants can unmute without host permission |

### Security
| Element | Notes |
|---|---|
| Checkbox — Enable waiting room | Participants must be admitted by host |
| Checkbox — Require password | Reveals password text field when ON |
| Text field — Meeting password | Only visible when password toggle is ON |
| Checkbox — Join before host | |

### Chat & Sharing (dropdowns)
| Dropdown | Options |
|---|---|
| Chat permissions | Everyone / Host Only / Disabled |
| Screen sharing | Host Only / Everyone / Request to Share |
| Share takeover | One at a Time / Host Can Take Over / Anyone Can Take Over |

### Recording & Transcription *(Pro-gated)*
| Checkbox | Notes |
|---|---|
| Auto-record to cloud | Disabled + amber callout for free tier |
| Auto-transcript | |
| Allow co-host local recording | |

### Actions
| Button | Notes |
|---|---|
| **Cancel** | Dismisses sheet |
| **Start Meeting ⏎** | Saves settings and starts the call |`
  },
  "green-room": {
    id: "green-room",
    title: "Green Room",
    description: "Camera and microphone preview screen shown immediately before joining a live session.",
    category: "Core Flows",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterPreMeetingPanel.m",
    mockComponent: GreenRoomMock,
    markdownSpec: `*Shown after a room code is entered — participants verify their camera and mic before entering the live call.*

| Element | Label | Action |
|---|---|---|
| Camera preview | Live or avatar placeholder | Visual check before entering |
| Name overlay | Editable text at bottom of preview | Sets display name for the session |
| Blur background toggle | "Blur bg" | Applies virtual background blur |
| Device row — Microphone | On/Off + Change \`^\` | Toggle mic; caret opens device picker |
| Device row — Camera | On/Off + Change \`^\` | Toggle camera; caret opens device picker |
| Device row — Speaker | Change \`^\` | Opens speaker device picker |
| Text link | "Test speaker & microphone…" | Opens audio test flow |
| Room code | Monospace display | Confirms which room is being joined |
| Network quality dot | Excellent / Good / Poor | Pre-join connectivity check |
| **Button** | **"Join Now"** | Enters the live call |
| Text link | "Join without video" | Enters call with camera off |`
  },
  "host-controls": {
    id: "host-controls",
    title: "Host In-Meeting Controls",
    description: "Full host view — moderation menu, recording indicator, share permissions, interview tool, participant panel, and dual Leave/End actions.",
    category: "Live Session",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterLocalCallControlPanel.m",
    mockComponent: HostInMeetingMock,
    markdownSpec: `### Host-only Control Bar additions
| Element | Notes |
|---|---|
| Recording button | Start / Stop Recording with elapsed timer |
| Recordings folder | Opens recordings panel |
| Screen Share Permission | Segmented: Everyone / Ask / Host Only |

> **Note:** the Interview Tool (Off/Code/Board) is **hidden in normal calls** — it appears
> only in the Secure Interview window, not here.

### Moderation Menu (three-dot per tile, host only)
| Item | Notes |
|---|---|
| Mute Mic / Unmute Mic | Toggles participant mic |
| Mute Camera / Unmute Camera | Toggles participant camera |
| Pin for All | Up to 5 simultaneous pins |
| Make Co-Host / Remove Co-Host | Promotes or demotes |
| Rename… | Opens rename dialog |
| **Remove from Meeting** | Red — destructive action |

### Participants Panel
| Element | Notes |
|---|---|
| Per-row mic toggle | Host can mute any participant |
| Admit All Waiting | Bulk-admits lobby queue |
| Mute All | Silences entire call |

### End Actions (isolated right)
| Button | Notes |
|---|---|
| Leave | Host leaves, call continues |
| **End for All** | Terminates session for everyone |`
  },
  "lobby": {
    id: "lobby",
    title: "Lobby & Waiting",
    description: "Host moderation surface for waiting-room participant admission.",
    category: "Live Session",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterLobbyPanel.m",
    mockComponent: LobbyMock,
    markdownSpec: `| Element | Label | Action |
|---|---|---|
| Waiting list rows | Name + role + wait time | Queue visibility |
| **Button** | **"Admit"** | Moves participant to active call |
| **Button** | **"Decline"** | Rejects join request |
| Count badge | "N Waiting" | Real-time queue indicator |`
  },
  "chat": {
    id: "chat",
    title: "Chat Panel",
    description: "Sidebar panel for messaging and file sharing.",
    category: "Collaboration",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterChatPanel.m",
    mockComponent: ChatMock,
    markdownSpec: `| Element | Label | Notes |
|---|---|---|
| Dropdown | **Recipient selector** | "Everyone" + individuals |
| Text field | \`Type a message…\` | Message input |
| **Button** | **"Send"** | Submits message |
| **Button** | **📎 Attach file** | Max 10 MB |
| Message rows | Sender + time + content | Blue=public, purple=DM |`
  },
  "qa": {
    id: "qa",
    title: "Q&A Panel",
    description: "Audience question management with vote-based prioritization.",
    category: "Collaboration",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterQAPanel.m",
    mockComponent: QAMock,
    markdownSpec: `| Element | Label | Action |
|---|---|---|
| Question row | Prompt + state | Displays answered/unanswered state |
| Vote counter | N votes | Priority signal |
| **Button** | **"Pin"** | Elevates question visibility |
| Filter badge | "Open" | Shows currently active feed |`
  },
  "poll": {
    id: "poll",
    title: "Poll Panel",
    description: "Live voting interface with real-time result visualization.",
    category: "Collaboration",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterPollPanel.m",
    mockComponent: PollMock,
    markdownSpec: `| Element | Label | Action |
|---|---|---|
| Poll prompt | Single question | Defines response context |
| Option rows | Label + percentage bar | Displays current distribution |
| Response badge | "Live • N responses" | Participation status |
| Progress bars | 0-100% | Immediate feedback per option |`
  },
  "teams": {
    id: "teams",
    title: "Teams Panel",
    description: "Workspace team management and operational grouping.",
    category: "Management",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterTeamsPanel.m",
    mockComponent: TeamsMock,
    markdownSpec: `| Element | Label | Action |
|---|---|---|
| Team card | Name + member count | Displays team summary |
| Status tag | Active / Inactive | Team availability |
| **Button** | **"Manage Team"** | Opens team settings |
| **Button** | **"Create Team"** | Starts team creation flow |`
  },
  "schedule": {
    id: "schedule",
    title: "Schedule Panel",
    description: "Calendar and upcoming meeting management.",
    category: "Collaboration",
    fidelity: "Hi-Fi",
    source: "inter/UI/Views/InterSchedulePanel.m",
    mockComponent: ScheduleMock,
    markdownSpec: `### Calendar
| Element | Label | Notes |
|---|---|---|
| **Button** | **"‹" / "›"** | Previous/next month |
| Day grid cells | Day numbers | Click selects date |

### New Meeting Form
| Element | Notes |
|---|---|
| Time picker | Hours/minutes |
| Text field | Meeting title — required |
| Dropdown | Duration (15 - 120 min) |
| Checkbox | Enable lobby |
| **Button** | **"Schedule Meeting"** |`
  },
  "secure": {
    id: "secure",
    title: "Secure Interview — Interviewer",
    description: "Interviewer's side of the locked, E2E-encrypted interview window — Off/Code/Board tool selector, shared code editor and whiteboard, preview rail, and a restricted chat overlay.",
    category: "Security",
    fidelity: "Hi-Fi",
    source: "inter/UI/Controllers/SecureWindowController.m",
    mockComponent: SecureInterviewMock,
    markdownSpec: `*The secure window is a full call window with interview tools. The **Off / Code / Board**
tool selector is visible **only here** (hidden in normal calls). Share publishes the active
tool surface only — never the desktop.*

### Main Window Controls
| Element | Shortcut | Action |
|---|---|---|
| **Button** | **"Exit Session"** (⌘Q) | Confirmation alert, then exits |
| **Button** | **"💬 Chat"** (⌘⇧C) | Toggles the floating chat overlay |
| Badge | "E2E Encrypted" / "Locked" | Session trust indicators |

### Control Panel (tool + media)
| Element | Options / Notes |
|---|---|
| Segmented — **Interview Tool** | "Off" / "Code" / "Board" — visible only in the secure window |
| **Button** — Share | Publishes the active tool surface only (disabled until a tool is picked) |
| Mic / Camera | Standard call media toggles |
| Share-mode dropdown / System-audio toggle | **Hidden** in secure mode |

### Share status label (4 states)
| State | Message |
|---|---|
| No tool | "Secure tool share is off. Choose a tool before you begin sharing." |
| Tool ready | "Secure tool share is off. [Tool] selected. Press Share to start publishing it." |
| Sharing | "Secure tool share is active. [Tool] visible to the other participant." |
| Paused | "Sharing is paused — select a tool to resume." |

### Interview Stage & Right Rail
| Element | Notes |
|---|---|
| Center stage | Switches between remote video and the active tool (code editor / whiteboard) |
| Preview cards | Per remote participant, share card, and tool preview ("Code Preview" / "Whiteboard Preview"); click promotes to center; selected = 2px blue border |

### Code Editor *(InterSecureCodeEditorView.m)*
| Element | Notes |
|---|---|
| Text view | 13pt monospaced, white-on-dark; ⌃F find bar; ⌘Z / ⌘⇧Z undo/redo |
| **All smart substitutions OFF** | Smart quotes, autocorrect, autocomplete, spell-check disabled (integrity) |
| Placeholder | "Open the secure editor and type here. Only this editor surface is shared in interview mode." |

### Whiteboard *(InterSecureWhiteboardView.m)*
| Element | Notes |
|---|---|
| Drawing surface | Freehand pen only, 3pt round stroke, subtle 32pt grid |
| Currently missing | Colors, eraser, undo/redo, shape tools, stroke-width control |

### Chat Overlay *(restricted)*
| Restriction | Notes |
|---|---|
| File sharing / download | **Disabled** — shows "File Sharing Unavailable in secure interview mode" |
| DM recipient selector | **Hidden** (single channel) |
| Export button | **Hidden** |
| Button tint | Gray (no unread) / blue (overlay visible) / orange (unread while hidden) |`
  },
  "secure-candidate": {
    id: "secure-candidate",
    title: "Secure Interview — Candidate",
    description: "Candidate's side of the locked, E2E-encrypted interview window — they pick a tool (code editor or whiteboard) and share their own surface, see the interviewer, a read-only recording indicator, and a chat that allows file sharing.",
    category: "Security",
    fidelity: "Hi-Fi",
    source: "inter/UI/Controllers/SecureWindowController.m",
    mockComponent: SecureInterviewCandidateMock,
    markdownSpec: `*The candidate runs the same secure window (§12) in a **candidate role**. They are the
active sharer: they pick a tool and publish their own editor/whiteboard surface. They cannot
record or moderate.*

### What the candidate can do
| Element | Notes |
|---|---|
| Segmented — **Share tool** | "Off" / "Code" / "Board" — candidate chooses which surface to share |
| **Button** — Share Tool | Publishes the selected surface to the interviewer (disabled until a tool is picked) |
| **Code editor** | The candidate's own surface, editable — **not collaborative** (only they type); smart substitutions OFF |
| **Whiteboard** | Freehand pen, 32pt grid |
| Mic / Camera toggles | Standard call media |
| **Button** — Leave / Leave Interview | Candidate exits the session |
| Chat overlay | **File sharing allowed** for the candidate; no DM selector, no export |

### What the candidate sees (read-only)
| Element | Notes |
|---|---|
| Recording indicator | "REC HH:MM:SS" — visible but **not controllable** (host controls recording) |
| E2E Encrypted / role chip | Trust + "Candidate" role indicator |
| Interviewer preview card | Interviewer video in the right rail; click to promote to center |

### What the candidate does NOT have (interviewer-only)
- Recording start/stop/pause controls
- Participant moderation (no three-dot menus, mute-others, remove, co-host)
- Exit confirmation (⌘Q) — they simply Leave

### Share status label (4 states)
| State | Message |
|---|---|
| No tool | "Pick a tool to share with your interviewer." |
| Tool ready | "[Tool] selected. Press Share to start showing it to your interviewer." |
| Sharing | "Sharing your [tool] with the interviewer." |
| Paused | "Sharing is paused — select a tool to resume." |`
  }
};
