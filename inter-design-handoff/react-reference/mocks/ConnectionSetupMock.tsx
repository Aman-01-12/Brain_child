import React, { useState } from "react";
import { Video, Users, Calendar, MonitorUp, Search, ChevronDown, Clock, MoreHorizontal, Copy } from "lucide-react";

const RECENTS = [
  { id: "A92K1Z", title: "Sprint Planning",   time: "Today, 10:00 AM",     participants: 8  },
  { id: "B74X9P", title: "Design Sync",       time: "Yesterday, 2:00 PM",  participants: 4  },
  { id: "C18Z2M", title: "Stakeholder Demo",  time: "Jun 6, 4:30 PM",      participants: 12 },
];

export function ConnectionSetupMock() {
  const [joinCode, setJoinCode] = useState("");
  const [joining, setJoining]   = useState(false);
  const [joined, setJoined]     = useState(false);
  const [copied, setCopied]     = useState<string | null>(null);

  const handleJoin = () => {
    if (!joinCode.trim()) return;
    setJoining(true);
    setTimeout(() => { setJoining(false); setJoined(true); }, 1200);
  };

  const handleCopy = (id: string) => {
    setCopied(id);
    setTimeout(() => setCopied(null), 1800);
  };

  return (
    <div className="w-[560px] bg-card rounded-2xl shadow-2xl overflow-hidden border border-border font-sans">

      {/* macOS titlebar */}
      <div className="h-11 bg-neutral-100/80 dark:bg-neutral-800/60 border-b border-border flex items-center px-4 gap-2">
        <span className="w-3 h-3 rounded-full bg-red-400" />
        <span className="w-3 h-3 rounded-full bg-amber-400" />
        <span className="w-3 h-3 rounded-full bg-green-400" />
        {/* Search — Zoom home pattern */}
        <div className="mx-auto flex items-center gap-1.5 h-6 px-3 rounded-md bg-neutral-200/70 dark:bg-neutral-700/60 text-xs text-neutral-400 w-52">
          <Search className="w-3 h-3 flex-shrink-0" />
          Search
        </div>
        {/* Profile chip */}
        <button className="flex items-center gap-1.5 ml-auto text-xs text-muted-foreground hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors">
          <div className="w-6 h-6 rounded-full bg-violet-500 flex items-center justify-center text-white text-[10px] font-bold select-none">
            AM
          </div>
          <ChevronDown className="w-3 h-3" />
        </button>
      </div>

      {/* Body */}
      <div className="p-6 space-y-6">

        {/* Welcome identity strip */}
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-full bg-violet-500 flex items-center justify-center text-white text-lg font-bold select-none flex-shrink-0">
            AM
          </div>
          <div>
            <div className="text-base font-semibold text-foreground">Good morning, Aman</div>
            <div className="text-xs text-muted-foreground">Personal Meeting ID: 283-748-2910</div>
          </div>
          <div className="ml-auto flex items-center gap-1.5 text-[11px] font-medium text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-800/30 px-2.5 py-1 rounded-full">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
            Online
          </div>
        </div>

        {/* Primary action tiles */}
        <div className="grid grid-cols-4 gap-3">
          {[
            { icon: <Video className="w-5 h-5" />,     label: "New Meeting",    color: "bg-violet-600 hover:bg-violet-700 text-white" },
            { icon: <Users className="w-5 h-5" />,     label: "Join",           color: "bg-secondary hover:bg-secondary text-foreground" },
            { icon: <Calendar className="w-5 h-5" />,  label: "Schedule",       color: "bg-secondary hover:bg-secondary text-foreground" },
            { icon: <MonitorUp className="w-5 h-5" />, label: "Share",          color: "bg-secondary hover:bg-secondary text-foreground" },
          ].map((a) => (
            <button key={a.label} className={`flex flex-col items-center justify-center gap-2 py-5 rounded-xl font-medium text-sm transition-colors ${a.color}`}>
              {a.icon}{a.label}
            </button>
          ))}
        </div>

        {/* Hosted room code display — "Room: XXXXXX" green monospace, only shown after hosting */}
        {joined && (
          <div className="flex items-center gap-2 px-3 py-2 rounded-lg bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-800/30">
            <span className="text-xs text-emerald-600 dark:text-emerald-400 font-medium">Room:</span>
            <span className="font-mono font-bold text-emerald-700 dark:text-emerald-300 tracking-widest">{joinCode || "A92K1Z"}</span>
            <button onClick={() => handleCopy(joinCode || "A92K1Z")} className="ml-auto text-[11px] text-emerald-600 hover:underline">Copy link</button>
            {copied && <span className="text-[11px] text-emerald-600 font-medium">Copied!</span>}
          </div>
        )}

        {/* Join via room code — strips confusable chars (0/O/1/I/L per inventory) */}
        {!joined ? (
          <div className="space-y-2">
            <div className="flex gap-2">
              <input
                value={joinCode}
                onChange={(e) => setJoinCode(
                  e.target.value.toUpperCase()
                    .replace(/[^A-Z0-9]/g, "")
                    .replace(/[0OIL]/g, c => ({ "0": "", "O": "", "I": "", "L": "" }[c] ?? c))
                    .slice(0, 6)
                )}
                onKeyDown={(e) => e.key === "Enter" && handleJoin()}
                placeholder="Enter room code — e.g. X7K29M"
                className="flex-1 h-9 rounded-lg border border-border bg-card px-3 font-mono text-sm uppercase tracking-widest text-foreground placeholder:text-neutral-400 placeholder:normal-case placeholder:tracking-normal focus:outline-none focus:border-violet-400 transition-colors"
              />
              {/* "Join with Room Code" — inventory exact label */}
              <button
                onClick={handleJoin}
                disabled={!joinCode.trim() || joining}
                className={`h-9 px-4 rounded-lg text-sm font-semibold transition-colors whitespace-nowrap ${
                  joinCode.trim() && !joining ? "bg-violet-600 hover:bg-violet-700 text-white" : "bg-muted text-neutral-400 cursor-not-allowed"
                }`}
              >
                {joining ? "Joining…" : "Join with Room Code"}
              </button>
            </div>
          </div>
        ) : (
          <div className="flex items-center gap-2 text-sm text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-800/30 rounded-lg px-4 py-2.5">
            <span className="w-2 h-2 rounded-full bg-emerald-500 flex-shrink-0" />
            Connected to room <span className="font-mono font-bold ml-1">{joinCode}</span>
          </div>
        )}

        {/* Host Interview button — PRO badge, connects directly without pre-meeting */}
        <div className="flex gap-3">
          <button
            onClick={() => { setJoined(true); setJoinCode("A92K1Z"); }}
            className="flex-1 h-9 rounded-lg bg-amber-500 hover:bg-amber-600 text-white text-sm font-semibold transition-colors flex items-center justify-center gap-2"
          >
            Host Interview
            <span className="text-[9px] font-bold bg-white/20 px-1.5 py-0.5 rounded-full tracking-wide">PRO</span>
          </button>
        </div>

        {/* Recent meetings */}
        <div>
          <div className="flex items-center justify-between mb-3">
            <span className="text-[11px] font-semibold text-muted-foreground uppercase tracking-wide">Recent</span>
            <button className="text-[11px] text-violet-600 dark:text-violet-400 font-medium hover:underline">See all</button>
          </div>
          <div className="space-y-1">
            {RECENTS.map((m) => (
              <div key={m.id} className="group flex items-center gap-3 px-3 py-2.5 rounded-xl hover:bg-muted transition-colors">
                {/* Meeting avatar */}
                <div className="w-8 h-8 rounded-lg bg-violet-100 dark:bg-violet-900/30 flex items-center justify-center flex-shrink-0">
                  <Video className="w-4 h-4 text-violet-600 dark:text-violet-400" />
                </div>
                {/* Details */}
                <div className="flex-1 min-w-0">
                  <div className="text-sm font-medium text-foreground truncate">{m.title}</div>
                  <div className="flex items-center gap-2 text-[11px] text-muted-foreground mt-0.5">
                    <Clock className="w-3 h-3" />
                    <span>{m.time}</span>
                    <span>·</span>
                    <Users className="w-3 h-3" />
                    <span>{m.participants}</span>
                  </div>
                </div>
                {/* Room code + actions (visible on hover) */}
                <div className="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                  <span className="font-mono text-[10px] text-muted-foreground">{m.id}</span>
                  <button
                    onClick={() => handleCopy(m.id)}
                    className="w-6 h-6 rounded-md flex items-center justify-center text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 hover:bg-secondary transition-colors"
                  >
                    <Copy className="w-3 h-3" />
                  </button>
                  <button className="w-6 h-6 rounded-md flex items-center justify-center text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 hover:bg-secondary transition-colors">
                    <MoreHorizontal className="w-3 h-3" />
                  </button>
                  <button
                    onClick={() => { setJoinCode(m.id); setJoined(false); }}
                    className="text-[11px] font-semibold text-white bg-violet-600 hover:bg-violet-700 rounded-md px-2.5 py-1 transition-colors ml-1"
                  >
                    Start
                  </button>
                </div>
                {copied === m.id && (
                  <span className="text-[11px] text-emerald-600 font-medium">Copied!</span>
                )}
              </div>
            ))}
          </div>
        </div>

      </div>
    </div>
  );
}
