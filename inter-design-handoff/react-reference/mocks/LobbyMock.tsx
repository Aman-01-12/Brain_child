import React, { useState } from "react";
import { MessageSquare, Users, Clock, Video, Loader2 } from "lucide-react";

const INITIAL = [
  { id: 1, name: "Alice Chen",   role: "Candidate",  wait: "Just now",   initial: "AC" },
  { id: 2, name: "Bob Smith",    role: "Observer",    wait: "1 min ago",  initial: "BS" },
  { id: 3, name: "Diana Prince", role: "Interviewer", wait: "Just now",   initial: "DP" },
];

type ParticipantState = "joining" | "waiting" | "waiting-queue" | "denied" | "admitted";

export function LobbyMock() {
  const [queue, setQueue]           = useState(INITIAL);
  const [waitingRoom, setWaitingRoom] = useState(true);
  const [view, setView]             = useState<"host" | "participant">("host");
  const [pState, setPState]         = useState<ParticipantState>("waiting");

  const admit = (id: number) => setQueue(q => q.filter(p => p.id !== id));
  const deny  = (id: number) => setQueue(q => q.filter(p => p.id !== id));
  const admitAll = () => setQueue([]);

  // Participant-side state config per inventory §7
  const PSTATE_CONFIG: Record<ParticipantState, {
    icon: React.ReactNode; title: string; message: string;
    color: string; btn: string | null; spinning: boolean;
  }> = {
    "joining":       { icon: <Video className="w-8 h-8" />,    title: "Joining Meeting",  message: "Connecting to the meeting…",                                              color: "text-violet-500",    btn: "Cancel",  spinning: true  },
    "waiting":       { icon: <Users className="w-8 h-8" />,    title: "Waiting Room",     message: "Please wait, the host will let you in shortly.",                         color: "text-violet-500",    btn: "Leave",   spinning: true  },
    "waiting-queue": { icon: <Users className="w-8 h-8" />,    title: "Waiting Room",     message: "Please wait, the host will let you in shortly.\nYour position in queue: 2", color: "text-violet-500", btn: "Leave",   spinning: true  },
    "denied":        { icon: <Users className="w-8 h-8" />,    title: "Access Denied",    message: "The host has denied your request to join.",                               color: "text-red-500",     btn: "OK",      spinning: false },
    "admitted":      { icon: <Users className="w-8 h-8" />,    title: "You're In!",       message: "Admitted. Connecting…",                                                   color: "text-emerald-500", btn: null,      spinning: false },
  };
  const pc = PSTATE_CONFIG[pState];

  return (
    <div className="w-[700px] font-sans space-y-3">
      {/* View toggle */}
      <div className="flex items-center gap-2 bg-card border border-border rounded-xl px-4 py-2.5">
        <span className="text-xs font-semibold text-muted-foreground mr-1">View:</span>
        {[
          { id: "host",        label: "Host Side"        },
          { id: "participant", label: "Participant Side"  },
        ].map(v => (
          <button key={v.id} onClick={() => setView(v.id as typeof view)}
            className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors ${view === v.id ? "bg-violet-600 text-white" : "bg-secondary text-muted-foreground hover:bg-muted"}`}>
            {v.label}
          </button>
        ))}
      </div>

      {view === "host" ? (
        /* ── HOST VIEW ── */
        <div className="bg-card rounded-xl border border-border shadow-xl overflow-hidden">
          <div className="px-5 py-3 border-b border-border flex items-center justify-between bg-muted">
            <div className="flex items-center gap-2.5">
              <Users className="w-4 h-4 text-neutral-500" />
              <span className="font-semibold text-sm text-foreground">Waiting Room</span>
              <span className="inline-flex items-center h-5 px-2 rounded-full bg-violet-100 dark:bg-violet-900/40 text-violet-700 dark:text-violet-300 text-[11px] font-semibold">{queue.length}</span>
            </div>
            <div className="flex items-center gap-2">
              <button className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground border border-border rounded-md px-3 py-1.5 hover:bg-accent transition-colors">
                <MessageSquare className="w-3.5 h-3.5" /> Message waiting room
              </button>
              {queue.length > 0 && (
                <button onClick={admitAll} className="text-xs font-semibold text-white bg-violet-600 hover:bg-violet-700 rounded-md px-3 py-1.5 transition-colors">
                  Admit All ({queue.length})
                </button>
              )}
            </div>
          </div>

          {/* "Enable Waiting Room" checkbox — inventory §6 */}
          <div className="px-5 py-2.5 border-b border-border flex items-center gap-2.5 bg-card">
            <div onClick={() => setWaitingRoom(v => !v)}
              className={`w-8 h-5 rounded-full cursor-pointer transition-colors flex-shrink-0 ${waitingRoom ? "bg-violet-600" : "bg-secondary"}`}>
              <span className={`block w-4 h-4 mt-0.5 rounded-full bg-white shadow transition-transform ${waitingRoom ? "translate-x-3.5" : "translate-x-0.5"}`} />
            </div>
            <span className="text-sm text-foreground cursor-pointer" onClick={() => setWaitingRoom(v => !v)}>Enable Waiting Room</span>
            <span className="text-xs text-muted-foreground">(disabled for co-hosts)</span>
          </div>

          <div className="px-5 pt-3 pb-1.5">
            <span className="text-[11px] font-semibold text-neutral-400 uppercase tracking-wide">Waiting to join</span>
          </div>

          <div className="px-5 pb-5 space-y-2">
            {queue.length === 0 ? (
              /* Empty state — exact inventory label */
              <div className="py-10 text-center text-sm text-neutral-400">No one is waiting</div>
            ) : queue.map((p) => (
              <div key={p.id} className="flex items-center gap-3 px-3 py-3 rounded-xl border border-border bg-card hover:bg-muted/40 transition-colors">
                <div className="w-9 h-9 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center text-[11px] font-bold text-violet-700 dark:text-violet-300 flex-shrink-0">{p.initial}</div>
                <div className="flex-1 min-w-0">
                  <div className="text-sm font-semibold text-foreground">{p.name}</div>
                  <div className="flex items-center gap-1.5 text-xs text-muted-foreground mt-0.5">
                    <span>{p.role}</span>·<Clock className="w-3 h-3" /><span>{p.wait}</span>
                  </div>
                </div>
                {/* "✕ Deny" (red) + "✓ Admit" (green) — exact inventory labels */}
                <div className="flex items-center gap-2">
                  <button onClick={() => deny(p.id)}
                    className="flex items-center gap-1 text-xs font-semibold text-red-500 border border-red-200 dark:border-red-800/40 rounded-md px-2.5 py-1.5 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors">
                    ✕ Deny
                  </button>
                  <button onClick={() => admit(p.id)}
                    className="flex items-center gap-1 text-xs font-semibold text-white bg-violet-600 hover:bg-violet-700 rounded-md px-2.5 py-1.5 transition-colors">
                    ✓ Admit
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      ) : (
        /* ── PARTICIPANT VIEW — 5 states per inventory §7 ── */
        <div className="bg-card rounded-xl border border-border shadow-xl overflow-hidden">
          <div className="px-4 py-2.5 border-b border-border bg-muted flex items-center gap-2">
            <span className="text-xs font-semibold text-muted-foreground">Participant state:</span>
            {(["joining","waiting","waiting-queue","denied","admitted"] as ParticipantState[]).map(s => (
              <button key={s} onClick={() => setPState(s)}
                className={`px-2 py-1 rounded-md text-[10px] font-semibold transition-colors ${pState === s ? "bg-violet-600 text-white" : "bg-secondary text-muted-foreground hover:bg-muted"}`}>
                {s}
              </button>
            ))}
          </div>
          <div className="flex flex-col items-center justify-center py-12 px-8 gap-5">
            <div className={`relative ${pc.color}`}>
              {pc.icon}
              {pc.spinning && (
                <Loader2 className="w-5 h-5 text-violet-500 animate-spin absolute -bottom-1 -right-1" />
              )}
            </div>
            <div className="text-center space-y-2">
              <h2 className="text-lg font-semibold text-foreground">{pc.title}</h2>
              {pc.message.split("\n").map((line, i) => (
                <p key={i} className="text-sm text-muted-foreground">{line}</p>
              ))}
            </div>
            {pc.btn && (
              <button onClick={() => setPState("joining")}
                className={`px-6 py-2 rounded-lg text-sm font-semibold transition-colors ${
                  pc.btn === "OK" ? "bg-violet-600 hover:bg-violet-700 text-white"
                  : "border border-border text-foreground hover:bg-muted"
                }`}>
                {pc.btn}
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
