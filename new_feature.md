# Inter: Product & Feature Strategy (March 2026)

This document outlines the strategic feature roadmap for Inter, designed for maximum market traction and sustainable growth. Our strategy is to use a generous Free tier to drive adoption, a powerful Pro tier for professional teams, and a specialized Hiring tier to solve high-value business problems.

## Core Philosophy

*   **Native Performance:** Faster, more efficient, and more integrated than web-based competitors.
*   **Simplicity & Design:** A clean, intuitive, and beautiful UI that respects user focus.
*   **Generosity:** A free tier that is genuinely useful, not a crippled demo.

---

## Feature & Tier Matrix

| Feature | Free Tier | Pro Tier | Hiring Tier |
| :--- | :--- | :--- | :--- |
| **Core Experience** | | | |
| Max Participants | **50** | **50** | **50** |
| Meeting Duration | **90 Minutes** | **Unlimited** | **Unlimited** |
| Video/Audio Quality | HD (720p) | Full HD (1080p) | Full HD (1080p) |
| End-to-End Encryption | ✅ | ✅ | ✅ |
| **Large Meeting Layout** | | | |
| Stage & Filmstrip UI | ✅ | ✅ | ✅ |
| Active Speaker Detection | ✅ | ✅ | ✅ |
| **Large Meeting Management** | | | |
| Roles & Permissions | Host & Participant | **Host, Co-host, Presenter** | **Host, Co-host, Presenter** |
| "Raise Hand" & Speaker Queue | ✅ (Basic chronological queue) | ✅ (Advanced managed queue: reorder speakers, add notes) |
| Advanced Moderation | ❌ | ✅ (Mute All, Disable Chat) | ✅ (Mute All, Disable Chat) |
| Lobby / Waiting Room | ❌ | ✅ | ✅ |
| **In-Meeting Chat** | | | |
| Public Chat to Everyone | ✅ | ✅ | ✅ |
| Direct Messaging (DMs) | ❌ | ✅ | ✅ |
| Save Chat Transcript | ❌ | ✅ | ✅ |
| **Recording & Content** | | | |
| Local Recording | ✅ (with watermark) | ✅ (no watermark) | ✅ (no watermark) |
| Cloud Recording | ❌ | **10 hours/user/month** | **20 hours/user/month** |
| Auto-Transcription | ❌ | ✅ | ✅ |
| Multi-track Recording | ❌ | ❌ | ✅ |
| **Productivity & Workflow** | | | |
| Calendar Integration | View upcoming meetings | **Schedule & manage meetings** | **Schedule & manage meetings** |
| Scheduling Links | ❌ | ✅ (like Calendly) | ✅ |
| Team Management | ❌ | ✅ | ✅ |
| Custom Branding | ❌ | ✅ (Lobby logo) | ✅ (Lobby logo & colors) |
| **Interview-Specific Features** | | | |
| Structured Interviews | ❌ | ❌ | ✅ |
| Live Coding & Whiteboard | ❌ | ❌ | ✅ |
| ATS Integration | ❌ | ❌ | ✅ (Greenhouse, Lever) |
| Candidate Dashboard | ❌ | ❌ | ✅ |
| **AI & "Magic" Features** | | | |
| AI Co-Pilot (Summaries) | ❌ | ❌ | ✅ (Usage-based add-on) |
| Automated Camera Framing | ✅ | ✅ | ✅ |
| Low-Light Correction | ✅ | ✅ | ✅ |

---

## Deep Dive: Recording Architecture

Recording is a core feature with powerful implications for our Pro and Hiring tiers. Control and consent are paramount.

### Recording Permissions

*   **Who Can Record:** Only the **Host** or a designated **Co-host** (Pro/Hiring feature) can initiate a recording.
*   **Consent & Notification:** When recording starts, a prominent "REC" icon is shown to everyone, and an audio announcement is made. New participants joining a recorded meeting must explicitly consent before entering.

### Recording Modes

When a host clicks "Record," they are presented with a choice. Based on our discussion, we will prioritize implementing these two modes:

#### 1. Default Mode: "Record Active Speaker with Shared Screen" (Available on all Tiers)

*   **Layout:** The final video file shows the main screen share with a picture-in-picture overlay of the person who is currently speaking.
*   **Use Case:** This is the most common and useful format for webinars, presentations, and general meetings. It creates a clean, professional-looking video that is easy to follow.
*   **Tiering:**
    *   **Free:** Creates a watermarked video file, saved locally.
    *   **Pro/Hiring:** Creates a non-watermarked file, with the option to save locally or to the cloud.

#### 2. Hiring Specific Mode: "Record Each Participant as a Separate Track" (Hiring Tier Only)

*   **Layout:** This mode does not produce a single video file. Instead, it saves a separate, isolated video file and audio file for every single participant.
*   **Use Case:** This is a high-value feature for creative agencies, marketing teams, and hiring managers who need maximum flexibility in post-production. They can use these separate tracks to edit together highlight reels, training materials, or perfectly polished interview summaries.
*   **Tiering:** This is a premium feature exclusive to the **Hiring** tier, saved to the cloud. It represents a significant technical and business value proposition that justifies the top-tier pricing.

---

## Deep Dive: Large Meeting Strategy (17-100+ Participants)

Our strategy is to provide the core usability for free, while monetizing the professional management tools.

*   **What's Free:** The basic user experience for a large meeting is available to all users. This includes the **Stage & Filmstrip layout**, **pagination**, and the underlying **selective subscription technology**. This ensures the app feels robust and high-quality for everyone, which is essential for our product-led growth.

*   **What's Paid (Pro & Hiring Tiers):** We monetize the tools required to *manage* a large meeting effectively. This includes:
    *   **Roles & Permissions:** The ability to designate co-hosts and presenters.
    *   **Moderation Controls:** "Mute All," "Disable Chat," and a "Lobby" to screen participants.
    *   **Interaction Management:** A structured "Raise Hand" queue and a formal Q&A panel.

This approach ensures our free product is best-in-class, driving adoption, while creating a clear and compelling reason for professional users to upgrade.
