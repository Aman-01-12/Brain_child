import React, { useState, useEffect, useRef } from "react";
import {
  Mic, MicOff, Video, VideoOff, MonitorUp, MoreHorizontal, Hand, Shield,
  PhoneOff, Users, MessageSquare, Smile, ChevronUp, ChevronLeft, ChevronRight,
  MonitorPlay, LayoutGrid, Pin, Folder, ChevronDown, Lock, LockOpen,
  UserMinus, UserCog, Pencil, X, Volume2,
} from "lucide-react";

// ─── Types ────────────────────────────────────────────────────────────────────
type NetQuality = "unknown" | "lost" | "poor" | "good" | "excellent";
type RecState   = "off" | "active" | "paused";
type SharePerm  = "Everyone" | "Ask" | "Host Only";

type Participant = {
  id: number; name: string; initial: string;
  micMuted: boolean; camMuted: boolean; camLocked: boolean;
  handRaised: boolean; cohost: boolean; pinned: boolean;
  speaking: boolean; you: boolean;
};

// ─── Network quality bars ─────────────────────────────────────────────────────
const NET_CONFIG: Record<NetQuality, { bars: number; color: string }> = {
  unknown:   { bars: 0, color: "bg-neutral-500" },
  lost:      { bars: 1, color: "bg-red-500"     },
  poor:      { bars: 2, color: "bg-orange-500"  },
  good:      { bars: 3, color: "bg-yellow-400"  },
  excellent: { bars: 4, color: "bg-emerald-500" },
};

function NetBars({ quality }: { quality: NetQuality }) {
  const { bars, color } = NET_CONFIG[quality];
  return (
    <div className="flex items-end gap-0.5 h-4">
      {[1, 2, 3, 4].map(n => (
        <div key={n}
          className={`w-1 rounded-sm transition-all ${n <= bars ? color : "bg-white/15"}`}
          style={{ height: `${25 * n}%` }}
        />
      ))}
    </div>
  );
}

// ─── Control button ───────────────────────────────────────────────────────────
function CtrlBtn({ icon, label, active, danger, badge, hasMenu, onClick, dim }: {
  icon: React.ReactNode; label: string; active?: boolean; danger?: boolean;
  badge?: string | number; hasMenu?: boolean; onClick?: () => void; dim?: boolean;
}) {
  const tone = danger
    ? "text-red-400 bg-red-500/15 hover:bg-red-500/25"
    : active
      ? "text-white bg-white/12 hover:bg-white/18"
      : dim
        ? "text-neutral-600 cursor-not-allowed"
        : "text-neutral-300 hover:bg-white/10";
  return (
    <button type="button" onClick={onClick} disabled={dim}
      className={`relative flex flex-col items-center justify-center gap-1 h-14 min-w-[58px] px-3 rounded-lg transition-colors select-none ${tone}`}>
      <span className="relative flex items-center justify-center">
        {icon}
        {badge !== undefined && (
          <span className="absolute -top-2 -right-3 min-w-[16px] h-4 px-1 rounded-full bg-violet-500 text-white text-[10px] font-semibold flex items-center justify-center">
            {badge}
          </span>
        )}
        {hasMenu && <ChevronUp className="w-2.5 h-2.5 absolute -top-1.5 -right-3 text-neutral-500" />}
      </span>
      <span className="text-[10px] font-medium leading-none">{label}</span>
    </button>
  );
}

// ─── Moderation context menu ──────────────────────────────────────────────────
function ModerationMenu({ p, onMuteMic, onMuteCam, onLockCam, onPin, onCohost, onRemove, onClose }: {
  p: Participant;
  onMuteMic: () => void; onMuteCam: () => void; onLockCam: () => void;
  onPin: () => void; onCohost: () => void; onRemove: () => void; onClose: () => void;
}) {
  return (
    <div className="absolute top-8 right-1 z-50 w-52 bg-[var(--stage-elevated)] border border-white/10 rounded-xl shadow-2xl overflow-hidden py-1" onClick={e => e.stopPropagation()}>
      <div className="px-3 py-2 text-[10px] text-neutral-500 font-bold uppercase tracking-wide border-b border-white/5">{p.name}</div>
      {/* Mic */}
      <button onClick={onMuteMic} className="w-full text-left px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10 flex items-center gap-2.5">
        {p.micMuted ? <Mic className="w-3.5 h-3.5 text-neutral-400" /> : <MicOff className="w-3.5 h-3.5 text-neutral-400" />}
        {p.micMuted ? "Unmute Mic" : "Mute Mic"}
      </button>
      {/* Camera */}
      <button onClick={onMuteCam} className="w-full text-left px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10 flex items-center gap-2.5">
        {p.camMuted ? <Video className="w-3.5 h-3.5 text-neutral-400" /> : <VideoOff className="w-3.5 h-3.5 text-neutral-400" />}
        {p.camMuted ? "Unmute Camera" : "Mute Camera"}
      </button>
      {/* Camera lock */}
      <button onClick={onLockCam} className="w-full text-left px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10 flex items-center gap-2.5">
        {p.camLocked ? <LockOpen className="w-3.5 h-3.5 text-neutral-400" /> : <Lock className="w-3.5 h-3.5 text-neutral-400" />}
        {p.camLocked ? "Unlock Camera" : "Lock Camera"}
      </button>
      <div className="border-t border-white/5 my-1" />
      {/* Pin */}
      <button onClick={onPin} className="w-full text-left px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10 flex items-center gap-2.5">
        <Pin className="w-3.5 h-3.5 text-neutral-400" />
        {p.pinned ? "Unpin for All" : "Pin for All"}
      </button>
      <div className="border-t border-white/5 my-1" />
      {/* Co-host */}
      <button onClick={onCohost} className="w-full text-left px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10 flex items-center gap-2.5">
        <UserCog className="w-3.5 h-3.5 text-neutral-400" />
        {p.cohost ? "Remove Co-Host" : "Make Co-Host"}
      </button>
      {/* Rename */}
      <button className="w-full text-left px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10 flex items-center gap-2.5">
        <Pencil className="w-3.5 h-3.5 text-neutral-400" /> Rename…
      </button>
      <div className="border-t border-white/5 my-1" />
      {/* Remove */}
      <button onClick={onRemove} className="w-full text-left px-3 py-2 text-[13px] text-red-400 hover:bg-red-500/15 flex items-center gap-2.5">
        <UserMinus className="w-3.5 h-3.5" /> Remove from Meeting
      </button>
      <div className="border-t border-white/5 my-1" />
      <button onClick={onClose} className="w-full text-left px-3 py-2 text-[11px] text-neutral-500 hover:bg-white/5 flex items-center gap-2">
        <X className="w-3 h-3" /> Close
      </button>
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────
export function HostInMeetingMock() {
  // ── Own media state ──
  const [micOn,    setMicOn]    = useState(true);
  const [camOn,    setCamOn]    = useState(true);
  const [shareOn,  setShareOn]  = useState(false);
  const [shareMode, setShareMode] = useState<"Share Window" | "Share Entire Screen">("Share Window");
  const [sysAudio, setSysAudio] = useState(false);
  const [audioSrc, setAudioSrc] = useState("MacBook Air Microphone");

  // ── Recording ──
  const [recState, setRecState] = useState<RecState>("active");
  const [recSecs,  setRecSecs]  = useState(877); // 14:37
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    if (recState === "active") {
      timerRef.current = setInterval(() => setRecSecs(s => s + 1), 1000);
    } else {
      if (timerRef.current) clearInterval(timerRef.current);
    }
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [recState]);

  const recLabel = [
    Math.floor(recSecs / 3600).toString().padStart(2, "0"),
    Math.floor((recSecs % 3600) / 60).toString().padStart(2, "0"),
    (recSecs % 60).toString().padStart(2, "0"),
  ].join(":");

  // ── Session state ──
  const [sessionState, setSessionState] = useState<"active" | "waiting" | "all-left">("active");

  // ── Layout ──
  const [layout,   setLayout]   = useState<"grid" | "stage">("grid");
  const [page,     setPage]     = useState(0);

  // ── Host-only controls ──
  const [sharePerm,     setSharePerm]     = useState<SharePerm>("Host Only");
  const [netQuality,    setNetQuality]    = useState<NetQuality>("excellent");
  const NET_CYCLE: NetQuality[] = ["excellent", "good", "poor", "lost", "unknown"];

  // ── Panels ──
  const [showParticipants, setShowParticipants] = useState(true);
  const [handRaised,       setHandRaised]       = useState(false);
  const [menuForId,        setMenuForId]        = useState<number | null>(null);

  // ── Participants (mutable state) ──
  const [parts, setParts] = useState<Participant[]>([
    { id: 0, name: "You (Host)", initial: "Y", micMuted: false, camMuted: false, camLocked: false, handRaised: false, cohost: false, pinned: false, speaking: false, you: true  },
    { id: 1, name: "Alice Chen", initial: "A", micMuted: false, camMuted: false, camLocked: false, handRaised: true,  cohost: false, pinned: true,  speaking: true,  you: false },
    { id: 2, name: "Bob Smith",  initial: "B", micMuted: true,  camMuted: false, camLocked: false, handRaised: false, cohost: false, pinned: false, speaking: false, you: false },
    { id: 3, name: "Diana P.",   initial: "D", micMuted: false, camMuted: false, camLocked: false, handRaised: false, cohost: true,  pinned: false, speaking: false, you: false },
  ]);

  const mutePart    = (id: number, key: "micMuted" | "camMuted" | "camLocked" | "handRaised" | "cohost" | "pinned") =>
    setParts(ps => ps.map(p => p.id === id ? { ...p, [key]: !p[key] } : p));
  const removePart  = (id: number) => { setParts(ps => ps.filter(p => p.id !== id)); setMenuForId(null); };

  // Derived
  const raisedCount   = parts.filter(p => p.handRaised && !p.you).length;
  const statusLabel   = [
    camOn  ? "Camera on"  : "Camera off",
    micOn  ? "Mic on."    : "Mic off.",
  ].join(", ");
  const shareLabel    = shareOn
    ? `Secure surface share is active (${shareMode}).`
    : "Secure surface share is off.";

  const gridParts = sessionState === "active" ? parts : [];
  const totalPages = Math.ceil(gridParts.length / 4);

  return (
    <div className="w-[1040px] bg-[var(--stage-surface)] rounded-xl overflow-hidden shadow-2xl flex flex-col font-sans border border-neutral-800" style={{ height: 596 }}>

      {/* ═══ TOP BAR ═══ */}
      <div className="flex-shrink-0 h-11 bg-black/40 border-b border-white/5 flex items-center justify-between px-4 gap-3">

        {/* Left: identity */}
        <div className="flex items-center gap-2.5">
          <span className="text-sm font-semibold text-white">Weekly Sync</span>
          <span className="font-mono text-[11px] text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded border border-emerald-500/15">A92K1Z</span>
          <div className="flex items-center gap-1 text-[11px] font-semibold text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded-md">
            <Shield className="w-3 h-3" /> Encrypted
          </div>
          <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-amber-400/15 text-amber-300 border border-amber-400/20 tracking-wide">HOST</span>
        </div>

        {/* Center: recording indicator (4E) */}
        {recState !== "off" && (
          <div className={`flex items-center gap-1.5 text-[11px] font-bold px-2.5 py-1 rounded-md border cursor-pointer select-none transition-colors ${
            recState === "active"
              ? "text-red-400 bg-red-500/10 border-red-500/20 hover:bg-red-500/20"
              : "text-amber-300 bg-amber-400/10 border-amber-400/20 hover:bg-amber-400/20"
          }`}
            onClick={() => setRecState(s => s === "active" ? "paused" : "active")}
          >
            <span className={`w-2 h-2 rounded-full ${recState === "active" ? "bg-red-400 animate-pulse" : "bg-amber-300"}`} />
            {recState === "active" ? "REC" : "PAUSED"} · <span className="font-mono">{recLabel}</span>
          </div>
        )}

        {/* Right: quality + layout + clock */}
        <div className="flex items-center gap-3">
          {/* Network quality bars (4F) — cycle through on click for demo */}
          <button title={`Network: ${netQuality}`} onClick={() => setNetQuality(q => NET_CYCLE[(NET_CYCLE.indexOf(q) + 1) % NET_CYCLE.length])}
            className="flex items-center gap-1.5 hover:bg-white/5 rounded px-1 py-0.5 transition-colors">
            <NetBars quality={netQuality} />
            <span className="text-[10px] text-neutral-500 capitalize">{netQuality}</span>
          </button>

          {/* Stage / Gallery toggle (4C) */}
          <div className="flex bg-white/5 border border-white/10 rounded-lg overflow-hidden">
            {(["gallery", "stage"] as const).map(v => (
              <button key={v} onClick={() => setLayout(v === "gallery" ? "grid" : "stage")}
                className={`flex items-center gap-1 px-2.5 h-7 text-[11px] font-medium transition-colors ${(v === "gallery" ? "grid" : "stage") === layout ? "bg-white/15 text-white" : "text-neutral-400 hover:text-neutral-200 hover:bg-white/10"}`}>
                {v === "stage" ? <MonitorPlay className="w-3 h-3" /> : <LayoutGrid className="w-3 h-3" />}
                {v === "stage" ? "Stage" : "Gallery"}
              </button>
            ))}
          </div>

          {/* Session state demo */}
          <select value={sessionState} onChange={e => setSessionState(e.target.value as typeof sessionState)}
            className="appearance-none bg-white/5 text-neutral-400 text-[10px] rounded-md px-2 py-1 border border-white/10 focus:outline-none cursor-pointer">
            <option value="active">Active</option>
            <option value="waiting">Waiting</option>
            <option value="all-left">All left</option>
          </select>

          <span className="text-[11px] text-neutral-500 font-medium tabular-nums">12:04</span>
        </div>
      </div>

      {/* ═══ MAIN CONTENT ═══ */}
      <div className="flex-1 min-h-0 flex bg-[var(--stage-surface)]">

        {/* Video tiles */}
        <div className="flex-1 relative">

          {/* 4D: Waiting overlay */}
          {sessionState === "waiting" && (
            <div className="absolute inset-0 flex flex-col items-center justify-center bg-[var(--stage-surface)] z-10">
              <span className="w-3 h-3 rounded-full bg-emerald-500 animate-pulse mb-4" />
              <p className="text-white font-semibold text-base">Waiting for participants…</p>
            </div>
          )}

          {/* 4D: All left overlay */}
          {sessionState === "all-left" && (
            <div className="absolute inset-0 flex flex-col items-center justify-center bg-[var(--stage-surface)] gap-4 z-10">
              <p className="text-white font-semibold">All participants left.</p>
              <div className="flex gap-3">
                <button onClick={() => setSessionState("waiting")} className="px-5 py-2 rounded-lg border border-white/20 text-sm font-semibold text-neutral-200 hover:bg-white/10 transition-colors">Wait</button>
                <button className="px-5 py-2 rounded-lg bg-red-500 hover:bg-red-600 text-white text-sm font-semibold transition-colors">End Call</button>
              </div>
            </div>
          )}

          {/* Grid */}
          {sessionState === "active" && (
            <div className="h-full p-2.5 grid grid-cols-2 gap-2.5">
              {gridParts.map((p) => (
                <div key={p.id}
                  onClick={() => setMenuForId(null)}
                  className={`relative rounded-xl overflow-hidden bg-neutral-900 group transition-all cursor-pointer ${
                    p.speaking ? "ring-2 ring-emerald-400" : "ring-1 ring-white/5 hover:ring-white/20"
                  }`}
                >
                  {/* Avatar / cam-off */}
                  <div className={`absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-800 to-neutral-900 ${p.camMuted || p.camLocked ? "" : ""}`}>
                    {(p.camMuted || p.camLocked) ? (
                      <div className="flex flex-col items-center gap-1.5">
                        <div className="w-14 h-14 rounded-full bg-neutral-700 flex items-center justify-center text-xl font-bold text-neutral-200 select-none">{p.initial}</div>
                        {p.camLocked && <span className="text-[10px] text-neutral-500">🔒 Camera locked</span>}
                      </div>
                    ) : (
                      <div className="w-14 h-14 rounded-full bg-neutral-700 flex items-center justify-center text-xl font-bold text-neutral-200 select-none">{p.initial}</div>
                    )}
                  </div>

                  {/* Top-left: hand raised ✋ */}
                  {p.handRaised && (
                    <div className="absolute top-2 left-2 w-6 h-6 rounded-md bg-yellow-400/90 flex items-center justify-center text-neutral-900 z-10">
                      <Hand className="w-3.5 h-3.5" />
                    </div>
                  )}

                  {/* Top-left: pinned indicator */}
                  {p.pinned && !p.handRaised && (
                    <div className="absolute top-2 left-2 w-6 h-6 rounded-md bg-violet-500/80 flex items-center justify-center z-10">
                      <Pin className="w-3 h-3 text-white" />
                    </div>
                  )}

                  {/* Top-right: cohost + three-dot menu */}
                  <div className="absolute top-2 right-2 flex items-center gap-1 z-10">
                    {p.cohost && <span className="px-1.5 h-5 rounded bg-amber-400/20 text-amber-300 text-[9px] font-bold flex items-center">Co-host</span>}
                    {!p.you && (
                      <button
                        onClick={e => { e.stopPropagation(); setMenuForId(menuForId === p.id ? null : p.id); }}
                        className="w-6 h-6 rounded-md bg-black/60 backdrop-blur text-white opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center"
                      >
                        <MoreHorizontal className="w-3.5 h-3.5" />
                      </button>
                    )}
                  </div>

                  {/* Moderation menu — open on click */}
                  {menuForId === p.id && !p.you && (
                    <ModerationMenu
                      p={p}
                      onMuteMic={() => mutePart(p.id, "micMuted")}
                      onMuteCam={() => mutePart(p.id, "camMuted")}
                      onLockCam={() => mutePart(p.id, "camLocked")}
                      onPin={() => mutePart(p.id, "pinned")}
                      onCohost={() => mutePart(p.id, "cohost")}
                      onRemove={() => removePart(p.id)}
                      onClose={() => setMenuForId(null)}
                    />
                  )}

                  {/* Bottom: name scrim + mic + camera-locked badges */}
                  <div className="absolute bottom-0 inset-x-0 h-10 bg-gradient-to-t from-black/80 to-transparent flex items-center justify-between px-2.5 z-10">
                    <span className="text-white text-[11px] font-medium truncate">{p.name}{p.you ? " 👑" : ""}</span>
                    <div className="flex items-center gap-1">
                      {p.camLocked && <span className="w-5 h-5 rounded-sm bg-orange-500/20 text-orange-300 flex items-center justify-center"><Lock className="w-3 h-3" /></span>}
                      {p.micMuted  && <span className="w-5 h-5 rounded-sm bg-red-500/20 text-red-300 flex items-center justify-center"><MicOff className="w-3 h-3" /></span>}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* 4C pagination bar — shown when > 4 tiles */}
          {gridParts.length > 4 && (
            <div className="absolute bottom-2.5 left-1/2 -translate-x-1/2 flex items-center gap-2 bg-black/60 backdrop-blur rounded-full px-3 py-1.5 z-10">
              <button onClick={() => setPage(p => Math.max(0, p - 1))} className="text-neutral-400 hover:text-white disabled:opacity-30 transition-colors" disabled={page === 0}>
                <ChevronLeft className="w-4 h-4" />
              </button>
              <span className="text-[11px] text-neutral-300 font-medium tabular-nums">Page {page + 1} of {totalPages}</span>
              <button onClick={() => setPage(p => Math.min(totalPages - 1, p + 1))} className="text-neutral-400 hover:text-white disabled:opacity-30 transition-colors" disabled={page >= totalPages - 1}>
                <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          )}
        </div>

        {/* Participants panel */}
        {showParticipants && (
          <div className="w-[200px] flex-shrink-0 border-l border-white/5 bg-[var(--stage)] flex flex-col">
            <div className="flex items-center justify-between px-3 py-2.5 border-b border-white/5">
              <span className="text-[11px] font-bold text-neutral-200 uppercase tracking-wide">Participants ({parts.length})</span>
              <button onClick={() => setShowParticipants(false)} className="text-neutral-600 hover:text-neutral-200 transition-colors"><X className="w-3.5 h-3.5" /></button>
            </div>
            <div className="flex-1 overflow-y-auto py-1">
              {parts.map(p => (
                <div key={p.id} className="group flex items-center gap-2 px-3 py-1.5 hover:bg-white/5 transition-colors">
                  <div className="w-7 h-7 rounded-full bg-neutral-700 flex items-center justify-center text-[11px] font-bold text-neutral-300 flex-shrink-0">{p.initial}</div>
                  <div className="flex-1 min-w-0">
                    <div className="text-[11px] text-neutral-200 truncate leading-tight flex items-center gap-1">
                      {p.name.split(" ")[0]}
                      {p.you && <span className="text-[9px] text-amber-300 font-bold">Host</span>}
                      {p.cohost && !p.you && <span className="text-[9px] text-amber-300/70 font-bold">Co</span>}
                    </div>
                    {p.handRaised && !p.you && <div className="text-[10px] text-yellow-400 leading-tight">✋ Raised</div>}
                    {p.pinned && <div className="text-[10px] text-violet-400 leading-tight">📌 Pinned</div>}
                  </div>
                  {/* Per-row mic toggle */}
                  {!p.you && (
                    <button onClick={() => mutePart(p.id, "micMuted")}
                      className={`w-5 h-5 flex-shrink-0 flex items-center justify-center rounded opacity-0 group-hover:opacity-100 transition-opacity ${p.micMuted ? "text-red-400" : "text-neutral-400 hover:text-neutral-200"}`}>
                      {p.micMuted ? <MicOff className="w-3 h-3" /> : <Mic className="w-3 h-3" />}
                    </button>
                  )}
                </div>
              ))}
            </div>
            <div className="border-t border-white/5 p-2 space-y-1">
              <button className="w-full text-[10px] font-bold text-white bg-violet-600 hover:bg-violet-700 rounded-lg py-1.5 transition-colors">
                Admit All Waiting (1)
              </button>
              <button onClick={() => setParts(ps => ps.map(p => p.you ? p : { ...p, micMuted: true }))}
                className="w-full text-[10px] text-neutral-400 hover:text-neutral-200 hover:bg-white/5 rounded-lg py-1.5 transition-colors">
                Mute All
              </button>
            </div>
          </div>
        )}
      </div>

      {/* ═══ HOST CONTROL BAR ═══ */}
      <div className="flex-shrink-0 bg-[var(--stage)] border-t border-white/5">

        {/* Secondary toolbar (host-only) */}
        <div className="flex items-center gap-3 px-4 py-1.5 border-b border-white/5 overflow-x-auto">

          {/* Screen share permission segmented */}
          <div className="flex items-center gap-1.5 flex-shrink-0">
            <span className="text-[9px] text-neutral-600 font-bold uppercase tracking-wide">Share:</span>
            <div className="flex bg-white/5 border border-white/10 rounded-md overflow-hidden">
              {(["Everyone", "Ask", "Host Only"] as const).map(v => (
                <button key={v} onClick={() => setSharePerm(v)}
                  className={`px-2 py-1 text-[10px] font-semibold transition-colors ${sharePerm === v ? "bg-white/15 text-white" : "text-neutral-500 hover:text-neutral-200"}`}>
                  {v}
                </button>
              ))}
            </div>
          </div>

          {/* Share mode dropdown */}
          <div className="flex items-center gap-1.5 flex-shrink-0">
            <span className="text-[9px] text-neutral-600 font-bold uppercase tracking-wide">Mode:</span>
            <div className="relative">
              <select value={shareMode} onChange={e => setShareMode(e.target.value as typeof shareMode)}
                className="appearance-none bg-white/5 text-neutral-300 text-[10px] rounded-md pl-2 pr-6 py-1 border border-white/10 focus:outline-none cursor-pointer">
                <option>Share Window</option>
                <option>Share Entire Screen</option>
              </select>
              <ChevronDown className="w-2.5 h-2.5 absolute right-1.5 top-1/2 -translate-y-1/2 text-neutral-500 pointer-events-none" />
            </div>
          </div>

          {/* Audio input source */}
          <div className="flex items-center gap-1.5 flex-shrink-0">
            <span className="text-[9px] text-neutral-600 font-bold uppercase tracking-wide">Audio in:</span>
            <div className="relative">
              <select value={audioSrc} onChange={e => setAudioSrc(e.target.value)}
                className="appearance-none bg-white/5 text-neutral-300 text-[10px] rounded-md pl-2 pr-6 py-1 border border-white/10 focus:outline-none cursor-pointer max-w-[140px]">
                <option>MacBook Air Microphone</option>
                <option>External USB Mic</option>
                <option>AirPods Pro</option>
              </select>
              <ChevronDown className="w-2.5 h-2.5 absolute right-1.5 top-1/2 -translate-y-1/2 text-neutral-500 pointer-events-none" />
            </div>
          </div>

          {/* Share system audio */}
          <label className="flex items-center gap-1.5 cursor-pointer flex-shrink-0">
            <div onClick={() => setSysAudio(v => !v)}
              className={`w-7 h-4 rounded-full transition-colors flex-shrink-0 ${sysAudio ? "bg-violet-600" : "bg-white/10"}`}>
              <span className={`block w-3 h-3 mt-0.5 rounded-full bg-white shadow transition-transform ${sysAudio ? "translate-x-3.5" : "translate-x-0.5"}`} />
            </div>
            <span className="text-[10px] text-neutral-500">System audio</span>
          </label>

          {/* Recording */}
          <div className="flex items-center gap-1 ml-auto flex-shrink-0">
            {recState === "off" ? (
              <button onClick={() => { setRecState("active"); setRecSecs(0); }}
                className="flex items-center gap-1.5 text-[10px] font-bold text-neutral-400 hover:text-red-400 border border-white/10 px-2.5 py-1 rounded-md hover:border-red-500/30 hover:bg-red-500/10 transition-colors">
                <span className="w-2 h-2 rounded-full bg-neutral-500" /> Start Recording
              </button>
            ) : (
              <div className="flex items-center gap-1">
                <button onClick={() => setRecState(s => s === "active" ? "paused" : "active")}
                  className={`flex items-center gap-1.5 text-[10px] font-bold px-2.5 py-1 rounded-md border transition-colors ${recState === "active" ? "text-red-400 bg-red-500/10 border-red-500/20" : "text-amber-300 bg-amber-400/10 border-amber-400/20"}`}>
                  <span className={`w-2 h-2 rounded-full ${recState === "active" ? "bg-red-400 animate-pulse" : "bg-amber-300"}`} />
                  {recState === "active" ? "Pause" : "Resume"}
                </button>
                <button onClick={() => setRecState("off")}
                  className="text-[10px] text-neutral-500 hover:text-red-400 border border-white/10 px-2 py-1 rounded-md hover:border-red-500/20 transition-colors">
                  Stop
                </button>
              </div>
            )}
            <button className="flex items-center gap-1 text-[10px] text-neutral-600 hover:text-neutral-300 hover:bg-white/5 px-2 py-1 rounded-md transition-colors">
              <Folder className="w-3 h-3" /> Recordings
            </button>
          </div>
        </div>

        {/* Status labels */}
        <div className="flex items-center gap-4 px-4 py-1 border-b border-white/5">
          <span className="text-[10px] text-neutral-600 font-mono">{statusLabel}</span>
          <span className="text-[10px] text-neutral-600 font-mono">{shareLabel}</span>
          {raisedCount > 0 && (
            <span className="text-[10px] text-yellow-400 font-semibold ml-auto">
              ✋ {raisedCount} raised hand{raisedCount > 1 ? "s" : ""}
            </span>
          )}
        </div>

        {/* Main control bar */}
        <div className="h-[64px] flex items-center justify-between px-4">
          {/* Primary */}
          <div className="flex items-center gap-0.5">
            <CtrlBtn icon={micOn ? <Mic className="w-5 h-5" /> : <MicOff className="w-5 h-5" />}
              label={micOn ? "Mute" : "Unmute"} active={micOn} danger={!micOn} hasMenu onClick={() => setMicOn(v => !v)} />
            <CtrlBtn icon={camOn ? <Video className="w-5 h-5" /> : <VideoOff className="w-5 h-5" />}
              label={camOn ? "Stop Video" : "Start Video"} active={camOn} danger={!camOn} hasMenu onClick={() => setCamOn(v => !v)} />
          </div>

          {/* Secondary */}
          <div className="flex items-center gap-0.5">
            <CtrlBtn icon={<Users className="w-5 h-5" />} label="Participants" badge={parts.length} active={showParticipants} onClick={() => setShowParticipants(v => !v)} />
            <CtrlBtn icon={<MessageSquare className="w-5 h-5" />} label="Chat" badge={2} />
            <CtrlBtn icon={<MonitorUp className="w-5 h-5" />} label={shareOn ? "Stop Share" : "Share"} active={shareOn} onClick={() => setShareOn(v => !v)} />
            <CtrlBtn icon={<Smile className="w-5 h-5" />} label="React" />
            <CtrlBtn icon={<Hand className="w-5 h-5" />} label="Raise Hand" active={handRaised} onClick={() => setHandRaised(v => !v)} />
            <CtrlBtn icon={<Lock className="w-5 h-5" />} label="Lock" />
            <CtrlBtn icon={<MoreHorizontal className="w-5 h-5" />} label="More" />
          </div>

          {/* Destructive — Leave vs End for All */}
          <div className="flex items-center gap-2">
            <button type="button" className="flex items-center gap-1.5 h-10 px-4 rounded-lg border border-red-500/30 text-red-400 text-[11px] font-bold hover:bg-red-500/10 transition-colors">
              <PhoneOff className="w-3.5 h-3.5" /> Leave
            </button>
            <button type="button"
              onClick={() => setSessionState("all-left")}
              className="flex items-center gap-1.5 h-10 px-4 rounded-lg bg-red-500 hover:bg-red-600 text-white text-[11px] font-bold shadow-lg shadow-red-500/20 transition-colors">
              <PhoneOff className="w-3.5 h-3.5" /> End for All
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
