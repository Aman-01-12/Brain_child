import React, { useState } from "react";
import {
  Mic,
  MicOff,
  Video,
  VideoOff,
  MonitorUp,
  MoreHorizontal,
  Hand,
  Shield,
  LayoutGrid,
  PhoneOff,
  Users,
  MessageSquare,
  Smile,
  ChevronUp,
  SignalHigh,
  MonitorPlay,
  Pin,
} from "lucide-react";
import { Badge } from "../ui/badge";

type ControlButtonProps = {
  icon: React.ReactNode;
  label: string;
  active?: boolean;
  danger?: boolean;
  badge?: string | number;
  hasMenu?: boolean;
  onClick?: () => void;
};

function ControlButton({ icon, label, active, danger, badge, hasMenu, onClick }: ControlButtonProps) {
  const base = "relative flex flex-col items-center justify-center gap-1 h-14 min-w-[60px] px-3 rounded-lg transition-colors select-none";
  const tone = danger
    ? "text-red-400 hover:bg-red-500/15"
    : active
      ? "text-white bg-white/10 hover:bg-white/15"
      : "text-neutral-300 hover:bg-white/10";

  return (
    <button type="button" onClick={onClick} className={`${base} ${tone}`}>
      <span className="relative flex items-center justify-center">
        {icon}
        {badge !== undefined && (
          <span className="absolute -top-2 -right-3 min-w-[16px] h-4 px-1 rounded-full bg-violet-500 text-white text-[10px] font-semibold flex items-center justify-center">
            {badge}
          </span>
        )}
        {hasMenu && <ChevronUp className="w-3 h-3 absolute -top-2 -right-3 text-neutral-400" />}
      </span>
      <span className="text-[11px] font-medium leading-none">{label}</span>
    </button>
  );
}

const PARTICIPANTS = [
  { name: "You (Host)", initial: "Y", speaking: false, you: true,    muted: false, cohost: false, handRaised: false },
  { name: "Alice Chen", initial: "A", speaking: true,  you: false,   muted: false, cohost: false, handRaised: true  },
  { name: "Bob Smith",  initial: "B", speaking: false, you: false,   muted: true,  cohost: false, handRaised: false },
  { name: "Diana Prince",initial:"D", speaking: false, you: false,   muted: false, cohost: true,  handRaised: false },
];

/** Shared chrome overlaid on every tile */
function TileChrome({ p, compact = false }: { p: typeof PARTICIPANTS[0]; compact?: boolean }) {
  return (
    <>
      {/* Top-left: hand raised */}
      {p.handRaised && (
        <div className={`absolute ${compact ? "top-1 left-1 w-5 h-5" : "top-2.5 left-2.5 w-7 h-7"} rounded-md bg-yellow-400/90 flex items-center justify-center text-neutral-900 shadow-sm z-10`}>
          <Hand className={compact ? "w-2.5 h-2.5" : "w-4 h-4"} />
        </div>
      )}

      {/* Top-right: co-host tag + more button */}
      {!compact && (
        <div className="absolute top-2.5 right-2.5 flex items-center gap-1.5 z-10">
          {p.cohost && (
            <span className="px-1.5 h-5 rounded bg-amber-400/20 text-amber-300 text-[10px] font-semibold flex items-center">
              Co-host
            </span>
          )}
          <button className="w-7 h-7 rounded-md bg-black/50 backdrop-blur text-white opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
            <MoreHorizontal className="w-4 h-4" />
          </button>
        </div>
      )}

      {/* Bottom scrim: name + mic */}
      <div className={`absolute bottom-0 inset-x-0 ${compact ? "h-7" : "h-10"} bg-gradient-to-t from-black/80 to-transparent flex items-center justify-between ${compact ? "px-1.5" : "px-3"} z-10`}>
        <span className={`text-white font-medium drop-shadow-md truncate ${compact ? "text-[9px]" : "text-xs"}`}>{p.name}</span>
        {p.muted && (
          <span className={`flex items-center justify-center ${compact ? "w-4 h-4" : "w-6 h-6"} rounded-sm bg-red-500/20 text-red-300`}>
            <MicOff className={compact ? "w-2.5 h-2.5" : "w-3.5 h-3.5"} />
          </span>
        )}
      </div>
    </>
  );
}

export function InCallMock() {
  const [micOn, setMicOn]         = useState(true);
  const [camOn, setCamOn]         = useState(true);
  const [shareOn, setShareOn]     = useState(false);
  const [handRaised, setHandRaised] = useState(false);
  const [layout, setLayout]       = useState<"grid" | "stage">("grid");
  // Index into PARTICIPANTS of who is "on stage"
  const [stageIdx, setStageIdx]   = useState(1); // Alice Chen (active speaker) by default

  const stageMain = PARTICIPANTS[stageIdx];
  const stageStrip = PARTICIPANTS.filter((_, i) => i !== stageIdx);

  return (
    <div className="w-full max-w-4xl aspect-[16/9] bg-[var(--stage-surface)] rounded-xl overflow-hidden shadow-2xl flex flex-col font-sans border border-neutral-800">

      {/* ── Top header bar ── */}
      <div className="flex-shrink-0 h-12 bg-black/30 border-b border-white/5 flex items-center justify-between px-4">
        <div className="flex items-center gap-3">
          <span className="text-sm font-medium text-white">Weekly Sync</span>
          <Badge variant="outline" className="bg-white/5 border-white/10 text-neutral-300 font-mono text-[11px]">
            A92K1Z
          </Badge>
          <div className="flex items-center gap-1 text-xs font-medium text-emerald-400 bg-emerald-500/10 px-2 py-1 rounded-md">
            <Shield className="w-3 h-3" /> Encrypted
          </div>
        </div>

        <div className="flex items-center gap-2">
          <div className="flex items-center gap-1.5 text-xs text-neutral-300">
            <SignalHigh className="w-4 h-4 text-emerald-400" />
            <span>Excellent</span>
          </div>

          {/* Stage / Grid toggle — inventory item 4C */}
          <div className="flex bg-white/5 border border-white/10 rounded-lg overflow-hidden">
            <button
              onClick={() => setLayout("stage")}
              className={`flex items-center gap-1.5 px-2.5 h-7 text-xs font-medium transition-colors ${
                layout === "stage"
                  ? "bg-white/15 text-white"
                  : "text-neutral-400 hover:text-neutral-200 hover:bg-white/10"
              }`}
            >
              <MonitorPlay className="w-3.5 h-3.5" /> Stage
            </button>
            <button
              onClick={() => setLayout("grid")}
              className={`flex items-center gap-1.5 px-2.5 h-7 text-xs font-medium transition-colors ${
                layout === "grid"
                  ? "bg-white/15 text-white"
                  : "text-neutral-400 hover:text-neutral-200 hover:bg-white/10"
              }`}
            >
              <LayoutGrid className="w-3.5 h-3.5" /> Gallery
            </button>
          </div>

          <span className="text-xs text-neutral-500 font-medium tabular-nums">12:04</span>
        </div>
      </div>

      {/* ── Video area ── */}
      <div className="flex-1 min-h-0 bg-[var(--stage-surface)]">

        {/* ── GALLERY layout ── 2×2 grid */}
        {layout === "grid" && (
          <div className="w-full h-full p-3 grid grid-cols-2 gap-3">
            {PARTICIPANTS.map((p, i) => (
              <div
                key={i}
                className={`relative rounded-lg overflow-hidden bg-neutral-900 group transition-all cursor-pointer ${
                  p.speaking ? "ring-2 ring-emerald-400" : "ring-1 ring-white/5"
                }`}
                onClick={() => { setStageIdx(i); setLayout("stage"); }}
                title="Click to put on stage"
              >
                <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-800 to-neutral-900">
                  <div className="w-14 h-14 rounded-full bg-neutral-700 flex items-center justify-center text-xl font-semibold text-neutral-200 select-none">
                    {p.initial}
                  </div>
                </div>
                <TileChrome p={p} />
                {/* Pin hint on hover */}
                <div className="absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none">
                  <div className="bg-black/60 rounded-lg px-2 py-1 flex items-center gap-1 text-[10px] text-white font-medium">
                    <Pin className="w-3 h-3" /> Stage
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* ── STAGE layout ── large primary + filmstrip */}
        {layout === "stage" && (
          <div className="w-full h-full flex flex-col">
            {/* Main large tile */}
            <div className="flex-1 min-h-0 p-3 pb-1.5">
              <div
                className={`relative w-full h-full rounded-xl overflow-hidden bg-neutral-900 group ${
                  stageMain.speaking ? "ring-2 ring-emerald-400" : "ring-1 ring-white/10"
                }`}
              >
                {/* Background / avatar */}
                <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-800 to-neutral-900">
                  <div className="w-24 h-24 rounded-full bg-neutral-700 flex items-center justify-center text-4xl font-semibold text-neutral-200 select-none">
                    {stageMain.initial}
                  </div>
                </div>

                {/* Active speaker pulse */}
                {stageMain.speaking && (
                  <div className="absolute top-3 left-3 flex items-center gap-1.5 bg-emerald-500/20 border border-emerald-500/30 rounded-full px-2 py-0.5 z-10">
                    <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
                    <span className="text-[11px] text-emerald-300 font-semibold">Speaking</span>
                  </div>
                )}

                <TileChrome p={stageMain} />

                {/* Return to grid button on hover */}
                <button
                  onClick={() => setLayout("grid")}
                  className="absolute top-3 right-3 opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-1 bg-black/60 hover:bg-black/80 rounded-lg px-2 py-1 text-[11px] text-white font-medium z-20"
                >
                  <LayoutGrid className="w-3 h-3" /> Gallery
                </button>
              </div>
            </div>

            {/* Filmstrip of remaining participants */}
            <div className="flex-shrink-0 h-[90px] px-3 pb-3 flex gap-2">
              {stageStrip.map((p, i) => {
                const origIdx = PARTICIPANTS.indexOf(p);
                return (
                  <button
                    key={i}
                    onClick={() => setStageIdx(origIdx)}
                    className={`relative flex-1 rounded-lg overflow-hidden bg-neutral-900 group transition-all ${
                      p.speaking ? "ring-2 ring-emerald-400" : "ring-1 ring-white/10 hover:ring-white/30"
                    }`}
                  >
                    <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-800 to-neutral-900">
                      <div className="w-8 h-8 rounded-full bg-neutral-700 flex items-center justify-center text-xs font-semibold text-neutral-300 select-none">
                        {p.initial}
                      </div>
                    </div>
                    <TileChrome p={p} compact />
                    {/* Hover: click to stage */}
                    <div className="absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity bg-black/30 pointer-events-none">
                      <Pin className="w-3 h-3 text-white" />
                    </div>
                  </button>
                );
              })}
            </div>
          </div>
        )}
      </div>

      {/* ── Control bar ── */}
      <div className="flex-shrink-0 h-[72px] bg-[var(--stage)] border-t border-white/5 flex items-center justify-between px-4">
        {/* Primary — mic + camera */}
        <div className="flex items-center gap-1">
          <ControlButton
            icon={micOn ? <Mic className="w-5 h-5" /> : <MicOff className="w-5 h-5" />}
            label={micOn ? "Mute" : "Unmute"}
            active={micOn} danger={!micOn} hasMenu
            onClick={() => setMicOn(!micOn)}
          />
          <ControlButton
            icon={camOn ? <Video className="w-5 h-5" /> : <VideoOff className="w-5 h-5" />}
            label={camOn ? "Stop Video" : "Start Video"}
            active={camOn} danger={!camOn} hasMenu
            onClick={() => setCamOn(!camOn)}
          />
        </div>

        {/* Secondary — grouped session actions */}
        <div className="flex items-center gap-1">
          <ControlButton icon={<Users className="w-5 h-5" />} label="Participants" badge={4} />
          <ControlButton icon={<MessageSquare className="w-5 h-5" />} label="Chat" badge={2} />
          <ControlButton
            icon={<MonitorUp className="w-5 h-5" />}
            label={shareOn ? "Stop Share" : "Share"}
            active={shareOn}
            onClick={() => setShareOn(!shareOn)}
          />
          <ControlButton icon={<Smile className="w-5 h-5" />} label="React" />
          <ControlButton
            icon={<Hand className="w-5 h-5" />}
            label="Raise Hand"
            active={handRaised}
            onClick={() => setHandRaised(!handRaised)}
          />
          <ControlButton icon={<MoreHorizontal className="w-5 h-5" />} label="More" />
        </div>

        {/* Destructive — isolated right */}
        <div className="flex items-center">
          <button
            type="button"
            className="flex items-center gap-2 h-11 px-5 rounded-lg bg-red-500 hover:bg-red-600 text-white text-sm font-semibold shadow-lg shadow-red-500/20 transition-colors"
          >
            <PhoneOff className="w-4 h-4" /> Leave
          </button>
        </div>
      </div>
    </div>
  );
}
