import React, { useState } from "react";
import {
  Shield, LogOut, MessageSquare, Mic, MicOff, Video, VideoOff,
  MonitorUp, Code2, PenTool, Send, X, Lock, Paperclip, Download, Circle,
} from "lucide-react";

// Secure Interview — CANDIDATE (interviewee) side. Same secure window
// (SecureWindowController.m, inventory §12) but from the candidate's perspective:
//  • Candidate PICKS the tool (Off/Code/Board) and SHARES their surface.
//  • The code editor is THEIRS and editable (not collaborative — only they type).
//  • Candidate CAN share files in chat.
//  • Recording indicator is READ-ONLY (they see it, can't start/stop it).
//  • No moderation / recording controls (interviewer-only).
// Stage surfaces are fixed-dark in both app appearances; the editor keeps its own
// theme (#1e1e2e / #cdd6f4) per the design spec.

const STARTER = `// Problem: Two Sum — return indices that add up to target.
function twoSum(nums, target) {
  // your solution here
  const seen = new Map();
  for (let i = 0; i < nums.length; i++) {

  }
}`;

type Tool   = "Off" | "Code" | "Board";
type Center = "interviewer" | "tool";

export function SecureInterviewCandidateMock() {
  const [tool, setTool]       = useState<Tool>("Code");
  const [center, setCenter]   = useState<Center>("tool");
  const [sharing, setSharing] = useState(true);
  const [micOn, setMicOn]     = useState(true);
  const [camOn, setCamOn]     = useState(true);
  const [chatOpen, setChatOpen] = useState(false);
  const [unread]              = useState(1);

  const toolReady = tool !== "Off";
  const toolLabel = tool === "Code" ? "Code editor" : tool === "Board" ? "Whiteboard" : "";

  // Share status — candidate publishes their own tool surface (inventory §12B states).
  const shareLabel =
      sharing && !toolReady ? "Sharing is paused — select a tool to resume."
    : !sharing && !toolReady ? "Pick a tool to share with your interviewer."
    : !sharing &&  toolReady ? `${toolLabel} selected. Press Share to start showing it to your interviewer.`
    : `Sharing your ${toolLabel.toLowerCase()} with the interviewer.`;

  const chatTint = chatOpen
    ? "bg-violet-600 text-white border-violet-500"
    : unread > 0
      ? "bg-amber-400/15 text-amber-300 border-amber-400/25"
      : "bg-white/5 text-neutral-300 border-white/10";

  const pickTool = (t: Tool) => { setTool(t); if (t !== "Off") setCenter("tool"); };

  return (
    <div className="w-[960px] font-sans">
      <div className="relative rounded-2xl border border-neutral-800 bg-[var(--stage-surface)] shadow-2xl overflow-hidden flex flex-col" style={{ height: 580 }}>

        {/* ═══ TOP BAR ═══ */}
        <div className="flex-shrink-0 h-11 bg-[var(--stage)] border-b border-white/5 flex items-center justify-between px-3 gap-3">
          <div className="flex items-center gap-2.5 min-w-0">
            <span className="text-sm font-semibold text-white truncate">Secure Interview</span>
            <span className="font-mono text-[11px] text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded border border-emerald-500/15">SEC-4F2A</span>
            <div className="flex items-center gap-1 text-[11px] font-semibold text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded-md">
              <Shield className="w-3 h-3" /> E2E Encrypted
            </div>
            {/* Read-only recording indicator — candidate sees it but can't control it */}
            <div className="flex items-center gap-1.5 text-[11px] font-bold text-red-400 bg-red-500/10 px-2 py-0.5 rounded-md border border-red-500/20" title="The host is recording this session">
              <Circle className="w-2 h-2 fill-red-400 animate-pulse" /> REC <span className="font-mono font-medium">14:37</span>
            </div>
          </div>
          <div className="flex items-center gap-2 flex-shrink-0">
            {/* Candidate role chip */}
            <span className="flex items-center gap-1 text-[10px] font-bold px-2 py-0.5 rounded-full bg-violet-500/15 text-violet-300 border border-violet-400/20 tracking-wide">
              CANDIDATE
            </span>
            <button
              onClick={() => setChatOpen(o => !o)}
              className={`flex items-center gap-1.5 h-7 px-2.5 rounded-md border text-[11px] font-semibold transition-colors ${chatTint}`}>
              <MessageSquare className="w-3 h-3" /> Chat
              {!chatOpen && unread > 0 && (
                <span className="ml-0.5 min-w-[14px] h-3.5 px-1 rounded-full bg-amber-400 text-[9px] font-bold text-neutral-900 flex items-center justify-center">{unread}</span>
              )}
              <span className="text-[9px] text-current/60 font-mono">⌘⇧C</span>
            </button>
            {/* Candidate leaves (no ⌘Q moderator confirm) */}
            <button className="flex items-center gap-1.5 h-7 px-2.5 rounded-md bg-red-500/10 hover:bg-red-500/20 border border-red-500/25 text-red-400 text-[11px] font-bold transition-colors">
              <LogOut className="w-3 h-3" /> Leave
            </button>
          </div>
        </div>

        {/* ═══ BODY — center stage + right rail ═══ */}
        <div className="flex-1 min-h-0 flex">

          {/* Center stage — candidate's editable tool OR the interviewer's video */}
          <div className="flex-1 min-w-0 relative bg-[#0d0d0f] flex flex-col">

            {/* CODE editor (theirs, editable — not collaborative) */}
            {center === "tool" && tool === "Code" && (
              <div className="absolute inset-0 flex flex-col bg-[#1e1e2e]">
                <div className="flex-shrink-0 h-8 flex items-center justify-between px-3 border-b border-white/10">
                  <div className="flex items-center gap-2 text-[11px] text-[#cdd6f4]">
                    <Code2 className="w-3.5 h-3.5" /> solution.js
                    <span className="text-[10px] text-[#6c7086]">JavaScript</span>
                  </div>
                  <span className="text-[9px] text-[#6c7086] font-mono">your editor · smart substitutions: OFF · ⌃F find</span>
                </div>
                <pre className="flex-1 overflow-auto p-4 text-[13px] font-mono leading-relaxed text-[#cdd6f4] whitespace-pre">{STARTER}<span className="inline-block w-1.5 h-4 align-text-bottom bg-[#cdd6f4]/70 animate-pulse" /></pre>
                <div className="flex-shrink-0 px-4 py-1.5 border-t border-white/10 text-[10px] text-[#6c7086]">
                  Only this editor surface is shared with your interviewer.
                </div>
              </div>
            )}

            {/* WHITEBOARD (theirs) */}
            {center === "tool" && tool === "Board" && (
              <div className="absolute inset-0 bg-[#16161a]">
                <svg className="w-full h-full" xmlns="http://www.w3.org/2000/svg">
                  <defs>
                    <pattern id="wb-grid-c" width="32" height="32" patternUnits="userSpaceOnUse">
                      <path d="M32 0H0V32" fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="1" />
                    </pattern>
                  </defs>
                  <rect width="100%" height="100%" fill="url(#wb-grid-c)" />
                  <path d="M140 200 C 190 150, 260 150, 300 200 S 410 250, 450 210" fill="none" stroke="#e5e7eb" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
                  <path d="M170 270 L 270 270 L 220 210 Z" fill="none" stroke="#cbd5e1" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
                <div className="absolute bottom-2 left-3 text-[10px] text-neutral-500">Your whiteboard · freehand pen · grid 32px</div>
              </div>
            )}

            {/* INTERVIEWER video mode */}
            {center === "interviewer" && (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-3">
                <div className="w-20 h-20 rounded-full bg-emerald-500/20 border border-emerald-400/30 flex items-center justify-center text-2xl font-bold text-emerald-300">DP</div>
                <span className="text-sm text-neutral-300 font-medium">Diana Prince</span>
                <span className="text-[11px] text-neutral-500">Interviewer · camera on</span>
              </div>
            )}

            {/* Self camera PiP */}
            <div className="absolute bottom-3 right-3 w-28 h-[72px] rounded-lg bg-[#101012] border border-white/10 shadow-lg flex items-center justify-center overflow-hidden">
              {camOn
                ? <span className="text-[10px] text-neutral-400">You (Candidate)</span>
                : <div className="w-9 h-9 rounded-full bg-white/10 flex items-center justify-center text-[11px] font-bold text-neutral-300">AC</div>}
            </div>
          </div>

          {/* Right rail — preview cards */}
          <div className="w-[180px] flex-shrink-0 bg-[var(--stage)] border-l border-white/5 flex flex-col">
            <div className="px-3 pt-3 pb-2">
              <span className="text-[10px] font-bold text-neutral-500 uppercase tracking-widest">Stage</span>
            </div>
            <div className="flex-1 overflow-y-auto px-2.5 space-y-2.5">
              {/* Interviewer card */}
              <button
                onClick={() => setCenter("interviewer")}
                className={`w-full rounded-lg overflow-hidden border-2 transition-colors ${center === "interviewer" ? "border-violet-500" : "border-transparent hover:border-white/15"}`}>
                <div className="aspect-video bg-[#101012] flex items-center justify-center">
                  <div className="w-9 h-9 rounded-full bg-emerald-500/20 flex items-center justify-center text-[11px] font-bold text-emerald-300">DP</div>
                </div>
                <div className="bg-white/5 px-2 py-1 text-left">
                  <div className="text-[10px] font-medium text-neutral-200 truncate">Diana Prince</div>
                  <div className="text-[9px] text-neutral-500">Interviewer</div>
                </div>
              </button>

              {/* Their shared tool preview */}
              {toolReady && (
                <button
                  onClick={() => setCenter("tool")}
                  className={`w-full rounded-lg overflow-hidden border-2 transition-colors ${center === "tool" ? "border-violet-500" : "border-transparent hover:border-white/15"}`}>
                  <div className={`aspect-video flex items-center justify-center ${tool === "Code" ? "bg-[#1e1e2e]" : "bg-[#16161a]"}`}>
                    {tool === "Code"
                      ? <Code2 className="w-5 h-5 text-[#cdd6f4]" />
                      : <PenTool className="w-5 h-5 text-neutral-300" />}
                  </div>
                  <div className="bg-white/5 px-2 py-1 text-left flex items-center gap-1">
                    <span className="text-[10px] font-medium text-neutral-200 truncate">
                      {tool === "Code" ? "Your Code" : "Your Board"}
                    </span>
                    {sharing && <span className="ml-auto w-1.5 h-1.5 rounded-full bg-emerald-400" />}
                  </div>
                </button>
              )}
            </div>
          </div>
        </div>

        {/* ═══ CONTROL PANEL ═══ */}
        <div className="flex-shrink-0 bg-[var(--stage)] border-t border-white/5">

          {/* Tool selector + share status — candidate chooses what to share */}
          <div className="flex items-center gap-3 px-4 py-1.5 border-b border-white/5">
            <div className="flex items-center gap-1.5 flex-shrink-0">
              <span className="text-[9px] text-neutral-600 font-bold uppercase tracking-wide">Share:</span>
              <div className="flex bg-white/5 border border-white/10 rounded-md overflow-hidden">
                {(["Off", "Code", "Board"] as const).map(v => (
                  <button key={v} onClick={() => pickTool(v)}
                    className={`flex items-center gap-1 px-2.5 py-1 text-[10px] font-semibold transition-colors ${
                      tool === v
                        ? (v === "Off" ? "bg-white/10 text-neutral-300" : "bg-violet-500/25 text-violet-200")
                        : "text-neutral-500 hover:text-neutral-200"}`}>
                    {v === "Code" && <Code2 className="w-3 h-3" />}
                    {v === "Board" && <PenTool className="w-3 h-3" />}
                    {v}
                  </button>
                ))}
              </div>
            </div>
            <span className="text-[10px] text-neutral-500 font-mono truncate">{shareLabel}</span>
          </div>

          {/* Main control bar — mic / camera / share | leave */}
          <div className="h-[60px] flex items-center justify-between px-4">
            <div className="flex items-center gap-2">
              <button onClick={() => setMicOn(v => !v)}
                className={`flex flex-col items-center justify-center w-14 h-11 rounded-lg gap-0.5 transition-colors ${micOn ? "bg-white/5 hover:bg-white/10 text-white" : "bg-red-500/15 text-red-400"}`}>
                {micOn ? <Mic className="w-4 h-4" /> : <MicOff className="w-4 h-4" />}
                <span className="text-[9px] font-medium leading-none">{micOn ? "Mute" : "Unmute"}</span>
              </button>
              <button onClick={() => setCamOn(v => !v)}
                className={`flex flex-col items-center justify-center w-14 h-11 rounded-lg gap-0.5 transition-colors ${camOn ? "bg-white/5 hover:bg-white/10 text-white" : "bg-red-500/15 text-red-400"}`}>
                {camOn ? <Video className="w-4 h-4" /> : <VideoOff className="w-4 h-4" />}
                <span className="text-[9px] font-medium leading-none">{camOn ? "Stop" : "Start"}</span>
              </button>
              <button
                onClick={() => toolReady && setSharing(s => !s)}
                disabled={!toolReady}
                title={!toolReady ? "Select a tool first" : undefined}
                className={`flex flex-col items-center justify-center w-16 h-11 rounded-lg gap-0.5 transition-colors ${
                  !toolReady ? "bg-white/5 text-neutral-600 cursor-not-allowed"
                  : sharing ? "bg-emerald-500/15 text-emerald-300" : "bg-white/5 hover:bg-white/10 text-white"}`}>
                <MonitorUp className="w-4 h-4" />
                <span className="text-[9px] font-medium leading-none">{sharing ? "Stop Share" : "Share Tool"}</span>
              </button>
            </div>

            <button className="flex items-center gap-1.5 h-10 px-4 rounded-lg bg-red-500 hover:bg-red-600 text-white text-[11px] font-bold shadow-lg shadow-red-500/20 transition-colors">
              <LogOut className="w-3.5 h-3.5" /> Leave Interview
            </button>
          </div>
        </div>

        {/* ═══ CHAT OVERLAY — candidate CAN share files (no DM selector / export) ═══ */}
        {chatOpen && (
          <div className="absolute bottom-[88px] right-3 w-64 rounded-xl bg-[var(--stage-elevated)] border border-white/10 shadow-2xl overflow-hidden flex flex-col z-20" style={{ height: 300 }}>
            <div className="flex-shrink-0 h-9 flex items-center justify-between px-3 border-b border-white/5">
              <span className="text-[11px] font-semibold text-white">Secure Chat</span>
              <button onClick={() => setChatOpen(false)} className="text-neutral-500 hover:text-neutral-200">
                <X className="w-3.5 h-3.5" />
              </button>
            </div>
            <div className="flex-1 overflow-y-auto p-3 space-y-2">
              <div className="text-[11px] text-neutral-300"><span className="font-semibold text-emerald-300">Diana:</span> Whenever you're ready, share your editor.</div>
              {/* Candidate-shared file (allowed) */}
              <div className="flex items-center gap-2 bg-white/5 border border-white/10 rounded-lg p-2 ml-auto w-44">
                <div className="w-7 h-7 rounded bg-violet-500/20 flex items-center justify-center text-violet-300 flex-shrink-0">
                  <Paperclip className="w-3 h-3" />
                </div>
                <div className="flex-1 min-w-0">
                  <div className="text-[11px] font-medium truncate text-neutral-200">resume.pdf</div>
                  <div className="text-[10px] text-neutral-500">182 KB</div>
                </div>
                <button className="text-neutral-400 hover:text-neutral-200 flex-shrink-0"><Download className="w-3.5 h-3.5" /></button>
              </div>
            </div>
            <div className="flex-shrink-0 p-2 border-t border-white/5 flex items-center gap-1.5">
              {/* Attach ENABLED for candidate */}
              <button title="Attach file" className="text-neutral-400 hover:text-neutral-200 flex-shrink-0">
                <Paperclip className="w-3.5 h-3.5" />
              </button>
              <input placeholder="Message…" className="flex-1 h-7 bg-white/5 border border-white/10 rounded-md px-2 text-[11px] text-neutral-200 placeholder:text-neutral-600 focus:outline-none" />
              <button className="w-7 h-7 rounded-md bg-violet-600 hover:bg-violet-700 flex items-center justify-center text-white flex-shrink-0">
                <Send className="w-3 h-3" />
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
