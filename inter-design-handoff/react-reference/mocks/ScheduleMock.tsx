import React, { useState } from "react";
import { ChevronLeft, ChevronRight, Clock, Video, VideoOff, Users, Copy, Link, Plus, Sparkles, Zap, ChevronDown } from "lucide-react";

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const CAL = Array.from({ length: 30 }, (_, i) => i + 1);
const MEETINGS = [
  { time: "10:00 AM", title: "Sprint Planning", duration: "45m", id: "A92K1Z" },
  { time: "2:00 PM",  title: "Design Sync",     duration: "30m", id: "B74X9P" },
  { time: "4:30 PM",  title: "Stakeholder Demo", duration: "1h",  id: "C18Z2M" },
];

export function ScheduleMock() {
  const [scenario, setScenario]               = useState<"first-time" | "returning">("first-time");
  const [selected, setSelected]               = useState(15);
  const [view, setView]                       = useState<"list" | "form">("list");
  const [hostVideo, setHostVideo]             = useState(true);
  const [participantVideo, setParticipantVideo] = useState(false);
  const [waitingRoom, setWaitingRoom]         = useState(true);
  const [recurrence, setRecurrence]           = useState(false);
  const [roomType, setRoomType]               = useState<"Call" | "Interview">("Call");
  const [schedPw, setSchedPw]                 = useState("");
  const [schedStatus, setSchedStatus]         = useState<"idle" | "saving" | "done" | "error">("idle");

  return (
    <div className="w-[860px] font-sans space-y-3">
      {/* Scenario toggle */}
      <div className="flex items-center gap-2 bg-card border border-border rounded-xl px-4 py-3">
        <span className="text-xs font-semibold text-muted-foreground mr-1">Scenario:</span>
        {[
          { id: "first-time", label: "First-time (full form)", icon: <Sparkles className="w-3 h-3" /> },
          { id: "returning",  label: "Defaults saved (quick schedule)", icon: <Zap className="w-3 h-3" /> },
        ].map(s => (
          <button key={s.id} onClick={() => setScenario(s.id as typeof scenario)}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
              scenario === s.id ? "bg-violet-600 text-white" : "bg-secondary text-muted-foreground hover:bg-muted"
            }`}>{s.icon} {s.label}</button>
        ))}
      </div>

      {/* RETURNING — quick schedule (pre-filled defaults) */}
      {scenario === "returning" ? (
        <div className="flex h-[500px] bg-card border border-border rounded-xl overflow-hidden shadow-xl">
          {/* Same calendar left pane */}
          <div className="w-[280px] flex-shrink-0 border-r border-border flex flex-col bg-muted">
            <div className="px-4 pt-4 pb-2">
              <div className="flex items-center justify-between mb-3">
                <button className="w-7 h-7 rounded-md flex items-center justify-center text-muted-foreground hover:bg-secondary transition-colors"><ChevronLeft className="w-4 h-4" /></button>
                <span className="text-sm font-semibold text-foreground">June 2026</span>
                <button className="w-7 h-7 rounded-md flex items-center justify-center text-muted-foreground hover:bg-secondary transition-colors"><ChevronRight className="w-4 h-4" /></button>
              </div>
              <div className="grid grid-cols-7 mb-1">{DAYS.map(d => <div key={d} className="text-[10px] text-center font-semibold text-muted-foreground py-1">{d}</div>)}</div>
              <div className="grid grid-cols-7 gap-y-0.5">
                <div className="aspect-square" />
                {CAL.map(d => {
                  const isSel = d === selected; const isToday = d === 8; const hasMeet = [12,15,22].includes(d);
                  return (
                    <div key={d} className="flex items-center justify-center aspect-square">
                      <button onClick={() => setSelected(d)} className={`w-7 h-7 rounded-full flex flex-col items-center justify-center text-xs relative transition-colors ${isSel ? "bg-violet-600 text-white font-semibold" : isToday ? "ring-2 ring-violet-400 font-semibold text-violet-600" : "text-foreground hover:bg-secondary"}`}>
                        {d}{hasMeet && <span className={`absolute bottom-0.5 w-1 h-1 rounded-full ${isSel ? "bg-white" : "bg-violet-500"}`} />}
                      </button>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
          {/* Quick schedule right pane */}
          <div className="flex-1 flex flex-col">
            <div className="flex-shrink-0 h-12 border-b border-border flex items-center px-5 bg-card justify-between">
              <div className="flex items-center gap-2">
                <span className="text-sm font-semibold text-foreground">Quick Schedule</span>
                <span className="text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-full bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-400 flex items-center gap-1"><Zap className="w-2.5 h-2.5" />Defaults saved</span>
              </div>
            </div>
            <div className="flex-1 p-5 space-y-4 overflow-y-auto">
              <div className="rounded-xl border border-border bg-muted p-4 space-y-2 text-sm">
                <p className="text-[11px] font-semibold text-muted-foreground uppercase tracking-wide mb-2">Your saved defaults</p>
                <div className="flex items-center justify-between"><span className="text-muted-foreground">Waiting room</span><span className="font-medium text-emerald-600">Enabled</span></div>
                <div className="flex items-center justify-between"><span className="text-muted-foreground">Host video</span><span className="font-medium text-foreground">On</span></div>
                <div className="flex items-center justify-between"><span className="text-muted-foreground">Participant video</span><span className="font-medium text-foreground">Off</span></div>
                <div className="flex items-center justify-between"><span className="text-muted-foreground">Screen sharing</span><span className="font-medium text-foreground">Host Only</span></div>
              </div>
              <div className="space-y-1.5">
                <label className="text-xs font-semibold text-foreground">Topic</label>
                <input defaultValue="Weekly Sync" className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400" />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <label className="text-xs font-semibold text-foreground">Start time</label>
                  <input type="time" defaultValue="14:00" className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400" />
                </div>
                <div className="space-y-1.5">
                  <label className="text-xs font-semibold text-foreground">Duration</label>
                  <select className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400">
                    <option>30 min</option><option selected>45 min</option><option>1 hr</option>
                  </select>
                </div>
              </div>
              <p className="text-xs text-muted-foreground">Go to <span className="font-semibold text-foreground">Settings → Meeting Defaults</span> to change your saved preferences.</p>
            </div>
            <div className="flex-shrink-0 border-t border-border px-5 py-3 flex justify-end gap-3 bg-muted">
              <button className="px-4 py-2 rounded-lg text-sm font-medium text-muted-foreground hover:bg-secondary transition-colors">Cancel</button>
              <button className="px-6 py-2 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors shadow-sm">Schedule</button>
            </div>
          </div>
        </div>
      ) : (

      /* FIRST-TIME — full form */
      <div className="flex h-[500px] bg-card border border-border rounded-xl overflow-hidden shadow-xl">

      {/* Left — calendar + meeting list */}
      <div className="w-[280px] flex-shrink-0 border-r border-border flex flex-col bg-muted">
        {/* Calendar header */}
        <div className="px-4 pt-4 pb-2">
          <div className="flex items-center justify-between mb-3">
            <button className="w-7 h-7 rounded-md flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors">
              <ChevronLeft className="w-4 h-4" />
            </button>
            <span className="text-sm font-semibold">June 2026</span>
            <button className="w-7 h-7 rounded-md flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors">
              <ChevronRight className="w-4 h-4" />
            </button>
          </div>
          {/* Day headers */}
          <div className="grid grid-cols-7 mb-1">
            {DAYS.map((d) => (
              <div key={d} className="text-[10px] text-center font-semibold text-muted-foreground py-1">{d}</div>
            ))}
          </div>
          {/* Date grid */}
          <div className="grid grid-cols-7 gap-y-0.5">
            <div className="aspect-square" />
            {CAL.map((d) => {
              const isSel   = d === selected;
              const isToday = d === 8;
              const hasMeet = [12, 15, 22].includes(d);
              return (
                <div key={d} className="flex items-center justify-center aspect-square">
                  <button
                    onClick={() => { setSelected(d); setView("list"); }}
                    className={`w-7 h-7 rounded-full flex flex-col items-center justify-center text-xs relative transition-colors ${
                      isSel   ? "bg-violet-600 text-white font-semibold" :
                      isToday ? "ring-2 ring-violet-400 font-semibold text-violet-600 dark:text-violet-400" :
                                "text-foreground hover:bg-secondary"
                    }`}
                  >
                    {d}
                    {hasMeet && (
                      <span className={`absolute bottom-0.5 w-1 h-1 rounded-full ${isSel ? "bg-white" : "bg-violet-500"}`} />
                    )}
                  </button>
                </div>
              );
            })}
          </div>
        </div>

        {/* Upcoming meetings — Hosted/Invited segmented per inventory §14 */}
        <div className="flex-1 border-t border-border overflow-y-auto p-3 space-y-2">
          <div className="flex items-center justify-between mb-2">
            <div className="flex bg-secondary rounded-md p-0.5">
              <button className="px-2 py-0.5 text-[10px] font-semibold bg-card rounded-sm shadow text-foreground">Hosted</button>
              <button className="px-2 py-0.5 text-[10px] font-semibold text-muted-foreground">Invited</button>
            </div>
          </div>
          {MEETINGS.map((m) => (
            <div key={m.id} className="rounded-lg border border-border bg-card p-2.5">
              <div className="text-xs font-semibold text-foreground truncate">{m.title}</div>
              <div className="flex items-center gap-1.5 text-[10px] text-muted-foreground mt-0.5">
                <Clock className="w-3 h-3" />{m.time} · {m.duration}
              </div>
              <div className="flex items-center gap-1 mt-2">
                {/* "Join" — only shown if roomCode available per inventory */}
                <button className="text-[10px] font-semibold text-white bg-violet-600 hover:bg-violet-700 rounded-md px-2 py-1 transition-colors">Join</button>
                {/* "Cancel" — hosted meetings only per inventory */}
                <button className="text-[10px] font-semibold text-red-500 border border-red-200 dark:border-red-800/40 rounded-md px-2 py-1 hover:bg-red-50 dark:hover:bg-red-900/10 transition-colors">Cancel</button>
                <span className="font-mono text-[10px] text-muted-foreground ml-auto">{m.id}</span>
                <button className="text-muted-foreground hover:text-foreground"><Copy className="w-3 h-3" /></button>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Right — Schedule A Meeting form (Zoom layout) */}
      <div className="flex-1 flex flex-col">
        <div className="flex-shrink-0 h-12 border-b border-border flex items-center justify-between px-5 bg-card">
          <h2 className="text-sm font-semibold">Schedule a Meeting</h2>
          <button
            onClick={() => setView(view === "form" ? "list" : "form")}
            className="flex items-center gap-1.5 text-xs font-semibold text-white bg-violet-600 hover:bg-violet-700 px-3 py-1.5 rounded-md transition-colors"
          >
            <Plus className="w-3.5 h-3.5" /> New Meeting
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-5 space-y-4">
          {/* Topic */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-foreground">Topic</label>
            <input
              defaultValue="Product Review"
              className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400"
            />
          </div>

          {/* Date + Time row */}
          <div className="grid grid-cols-3 gap-3">
            <div className="space-y-1.5 col-span-1">
              <label className="text-xs font-semibold text-foreground">Date</label>
              <div className="h-9 rounded-lg border border-border bg-card px-3 flex items-center text-sm text-foreground">
                June {selected}, 2026
              </div>
            </div>
            <div className="space-y-1.5">
              <label className="text-xs font-semibold text-foreground">Start time</label>
              <input type="time" defaultValue="14:00" className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400" />
            </div>
            <div className="space-y-1.5">
              <label className="text-xs font-semibold text-foreground">Duration</label>
              <select className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400">
                {/* Inventory §14 exact options: 15/20/30/45/60/90/120 min */}
                <option>15 min</option>
                <option>20 min</option>
                <option>30 min</option>
                <option selected>45 min</option>
                <option>60 min</option>
                <option>90 min</option>
                <option>120 min</option>
              </select>
            </div>
          </div>

          {/* Recurring */}
          <label className="flex items-center gap-2.5 cursor-pointer">
            <input type="checkbox" checked={recurrence} onChange={e => setRecurrence(e.target.checked)} className="rounded" />
            <span className="text-sm text-foreground">Recurring meeting</span>
          </label>

          {/* Video toggles — Zoom pattern */}
          <div className="space-y-1.5">
            <p className="text-xs font-semibold text-foreground">Video</p>
            <div className="grid grid-cols-2 gap-3">
              <div className="flex items-center justify-between rounded-lg border border-border bg-card px-3 py-2.5">
                <div className="flex items-center gap-2 text-sm text-foreground">
                  {hostVideo ? <Video className="w-4 h-4 text-violet-500" /> : <VideoOff className="w-4 h-4 text-neutral-400" />}
                  Host
                </div>
                <div className="flex gap-2 text-xs">
                  {["On","Off"].map(v => (
                    <button key={v} onClick={() => setHostVideo(v==="On")} className={`px-2 py-0.5 rounded font-medium transition-colors ${(v==="On") === hostVideo ? "bg-violet-600 text-white" : "text-neutral-500 hover:bg-secondary"}`}>{v}</button>
                  ))}
                </div>
              </div>
              <div className="flex items-center justify-between rounded-lg border border-border bg-card px-3 py-2.5">
                <div className="flex items-center gap-2 text-sm text-foreground">
                  <Users className="w-4 h-4 text-neutral-400" />
                  Participants
                </div>
                <div className="flex gap-2 text-xs">
                  {["On","Off"].map(v => (
                    <button key={v} onClick={() => setParticipantVideo(v==="On")} className={`px-2 py-0.5 rounded font-medium transition-colors ${(v==="On") === participantVideo ? "bg-violet-600 text-white" : "text-neutral-500 hover:bg-secondary"}`}>{v}</button>
                  ))}
                </div>
              </div>
            </div>
          </div>

          {/* Security */}
          <div className="space-y-2">
            <p className="text-xs font-semibold text-foreground">Security</p>
            <label className="flex items-start gap-2.5 cursor-pointer">
              <input type="checkbox" checked={waitingRoom} onChange={e => setWaitingRoom(e.target.checked)} className="rounded mt-0.5" />
              <div>
                <p className="text-sm text-foreground font-medium">Waiting Room</p>
                <p className="text-[11px] text-muted-foreground">Only users admitted by the host can join the meeting.</p>
              </div>
            </label>
          </div>

          {/* Invitees */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-foreground">Invite attendees</label>
            <input placeholder="alice@example.com, bob@example.com" className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground placeholder:text-neutral-400 focus:outline-none focus:border-violet-400" />
          </div>

          {/* Room Type — dropdown per inventory §14: "Call" / "Interview" */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-foreground">Room type</label>
            <div className="relative">
              <select value={roomType} onChange={e => setRoomType(e.target.value as typeof roomType)}
                className="w-full h-9 rounded-lg border border-border bg-card pl-3 pr-8 text-sm text-foreground focus:outline-none focus:border-violet-400 appearance-none">
                <option value="Call">Call</option>
                <option value="Interview">Interview</option>
              </select>
              <ChevronDown className="w-3.5 h-3.5 absolute right-2.5 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none" />
            </div>
            {roomType === "Interview" && <p className="text-[11px] text-muted-foreground">Includes code editor & whiteboard tools.</p>}
          </div>

          {/* Password — optional, per inventory §14 */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-foreground">Password <span className="font-normal text-muted-foreground">(optional)</span></label>
            <input type="password" value={schedPw} onChange={e => setSchedPw(e.target.value)}
              placeholder="Leave blank for none"
              className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground placeholder:text-neutral-400 focus:outline-none focus:border-violet-400" />
          </div>
        </div>

        {/* Footer CTA + Status label */}
        <div className="flex-shrink-0 border-t border-border px-5 py-3 bg-muted space-y-2">
          {schedStatus === "saving" && <p className="text-xs text-muted-foreground">Scheduling…</p>}
          {schedStatus === "done"   && <p className="text-xs text-emerald-600 font-semibold">✓ Meeting scheduled successfully.</p>}
          {schedStatus === "error"  && <p className="text-xs text-red-500 font-semibold">Failed to schedule. Please try again.</p>}
          <div className="flex justify-end gap-3">
            <button onClick={() => setSchedStatus("idle")} className="px-4 py-2 rounded-lg text-sm font-medium text-muted-foreground hover:bg-secondary transition-colors">Cancel</button>
            <button
              onClick={() => { setSchedStatus("saving"); setTimeout(() => setSchedStatus("done"), 1000); }}
              className="px-5 py-2 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors shadow-sm">
              Schedule Meeting
            </button>
          </div>
        </div>
      </div>

      {/* close flex-1 flex flex-col (right pane) */}
      </div>
      )}
    </div>
  );
}
