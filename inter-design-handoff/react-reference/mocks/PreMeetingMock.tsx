import React, { useState } from "react";
import { ChevronDown, Lock, Cloud, MessageSquare, Mic, Sparkles, Zap } from "lucide-react";

function SectionLabel({ children }: { children: React.ReactNode }) {
  return <div className="text-[10px] font-bold uppercase tracking-widest text-neutral-400 pt-1 pb-1.5">{children}</div>;
}

function CheckRow({ label, hint, checked, onChange }: {
  label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void;
}) {
  return (
    <label className="flex items-start gap-3 py-2 cursor-pointer group" onClick={() => onChange(!checked)}>
      <div className={`mt-0.5 w-4 h-4 rounded flex-shrink-0 flex items-center justify-center border transition-colors ${checked ? "bg-violet-600 border-violet-600" : "border-border group-hover:border-violet-400"}`}>
        {checked && (
          <svg width="9" height="7" viewBox="0 0 9 7" fill="none">
            <path d="M1 3.5L3.5 6L8 1" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        )}
      </div>
      <div>
        <div className="text-sm text-foreground">{label}</div>
        {hint && <div className="text-xs text-neutral-500 mt-0.5">{hint}</div>}
      </div>
    </label>
  );
}

function SelectRow({ label, value, options, onChange }: {
  label: string; value: string; options: string[]; onChange: (v: string) => void;
}) {
  return (
    <div className="flex items-center justify-between py-2">
      <div className="text-sm text-foreground">{label}</div>
      <div className="relative">
        <select value={value} onChange={e => onChange(e.target.value)}
          className="appearance-none h-8 pl-3 pr-7 rounded-lg border border-border bg-card text-sm text-foreground focus:outline-none focus:border-violet-400 transition-colors cursor-pointer"
        >
          {options.map(o => <option key={o}>{o}</option>)}
        </select>
        <ChevronDown className="w-3.5 h-3.5 absolute right-2 top-1/2 -translate-y-1/2 text-neutral-400 pointer-events-none" />
      </div>
    </div>
  );
}

export function PreMeetingMock() {
  const [scenario, setScenario]         = useState<"first-time" | "returning">("first-time");
  const [meetingName,    setMeetingName]    = useState("Aman's Meeting");
  const [muteMicAfter,   setMuteMicAfter]   = useState(false);
  const [camOffAfter,    setCamOffAfter]    = useState(false);
  const [allowUnmuting,  setAllowUnmuting]  = useState(true);
  const [waitingRoom,    setWaitingRoom]    = useState(true);
  const [requirePw,      setRequirePw]      = useState(false);
  const [password,       setPassword]       = useState("");
  const [joinBefore,     setJoinBefore]     = useState(false);
  const [chatPerm,       setChatPerm]       = useState("Everyone");
  const [sharePerm,      setSharePerm]      = useState("Host Only");
  const [takeover,       setTakeover]       = useState("One at a Time");
  const [autoRecord,     setAutoRecord]     = useState(false);
  const [autoTranscript, setAutoTranscript] = useState(false);
  const [cohostRec,      setCohostRec]      = useState(false);

  return (
    <div className="w-[560px] font-sans space-y-3">

      {/* Scenario toggle */}
      <div className="flex items-center gap-2 bg-card border border-border rounded-xl px-4 py-3">
        <span className="text-xs font-semibold text-muted-foreground mr-1">Scenario:</span>
        {[
          { id: "first-time", label: "First-time setup", icon: <Sparkles className="w-3 h-3" /> },
          { id: "returning",  label: "Settings saved",   icon: <Zap className="w-3 h-3" /> },
        ].map(s => (
          <button key={s.id} onClick={() => setScenario(s.id as typeof scenario)}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
              scenario === s.id
                ? "bg-violet-600 text-white"
                : "bg-secondary text-muted-foreground hover:bg-muted"
            }`}>
            {s.icon} {s.label}
          </button>
        ))}
      </div>

      {/* RETURNING — skips directly, shows confirmation */}
      {scenario === "returning" ? (
        <div className="bg-card rounded-2xl border border-border shadow-xl overflow-hidden">
          <div className="px-6 py-5 border-b border-border bg-muted">
            <h2 className="text-base font-semibold text-foreground">Starting your meeting…</h2>
            <p className="text-xs text-muted-foreground mt-0.5">Settings from your last session will be applied.</p>
          </div>
          <div className="px-6 py-5 space-y-3">
            <div className="rounded-xl border border-border bg-muted p-4 space-y-2 text-sm">
              <div className="flex items-center justify-between"><span className="text-muted-foreground">Meeting name</span><span className="font-medium text-foreground">Aman's Meeting</span></div>
              <div className="flex items-center justify-between"><span className="text-muted-foreground">Waiting room</span><span className="font-medium text-emerald-600">Enabled</span></div>
              <div className="flex items-center justify-between"><span className="text-muted-foreground">Chat</span><span className="font-medium text-foreground">Everyone</span></div>
              <div className="flex items-center justify-between"><span className="text-muted-foreground">Screen sharing</span><span className="font-medium text-foreground">Host Only</span></div>
            </div>
            <p className="text-xs text-muted-foreground">These were saved from your previous session. Go to <span className="font-semibold text-foreground">Settings → Meeting Defaults</span> to update them.</p>
          </div>
          <div className="px-6 py-4 border-t border-border flex gap-3 bg-muted">
            <button className="h-9 px-4 rounded-lg border border-border text-sm font-medium text-muted-foreground hover:bg-secondary transition-colors">Edit Settings</button>
            <button className="flex-1 h-9 rounded-lg bg-violet-600 hover:bg-violet-700 text-white text-sm font-semibold transition-colors flex items-center gap-2 justify-center">
              Start Meeting <kbd className="text-[10px] bg-violet-500/50 px-1 rounded font-mono">⏎</kbd>
            </button>
          </div>
        </div>
      ) : (

      /* FIRST-TIME — full settings sheet */
      <div className="bg-card rounded-2xl border border-border shadow-xl overflow-hidden">
        {/* Sheet header — first-time banner */}
        <div className="px-6 py-5 border-b border-border bg-muted">
          <div className="flex items-center gap-2 mb-2">
            <span className="inline-flex items-center gap-1 text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-full bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-400">
              <Sparkles className="w-2.5 h-2.5" /> First-time setup
            </span>
            <span className="text-[11px] text-muted-foreground">These become your saved defaults.</span>
          </div>
          <h2 className="text-base font-semibold text-foreground">Meeting Settings</h2>
          <p className="text-xs text-muted-foreground mt-0.5">Configure once — the next time you start a meeting these will apply automatically.</p>
        </div>

        {/* Body */}
        <div className="overflow-y-auto px-6 py-4 space-y-1" style={{ maxHeight: 440 }}>

          {/* General */}
          <SectionLabel>General</SectionLabel>
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-neutral-500">Meeting name</label>
            <input
              value={meetingName}
              onChange={e => setMeetingName(e.target.value)}
              className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400 transition-colors"
            />
          </div>

          <div className="border-t border-border my-3" />

          {/* Participant Controls */}
          <SectionLabel>
            <span className="flex items-center gap-1.5"><Mic className="w-3 h-3" /> Participant Controls</span>
          </SectionLabel>
          <CheckRow label="Mute mic after joining" checked={muteMicAfter} onChange={setMuteMicAfter} />
          <CheckRow label="Turn off camera after joining" checked={camOffAfter} onChange={setCamOffAfter} />
          <CheckRow label="Allow unmuting" hint="Participants can unmute themselves without host permission." checked={allowUnmuting} onChange={setAllowUnmuting} />

          <div className="border-t border-border my-3" />

          {/* Security */}
          <SectionLabel>
            <span className="flex items-center gap-1.5"><Lock className="w-3 h-3" /> Security</span>
          </SectionLabel>
          <CheckRow label="Enable waiting room (Lobby)" hint="Participants must be admitted by the host." checked={waitingRoom} onChange={setWaitingRoom} />
          <CheckRow label="Require meeting password" checked={requirePw} onChange={setRequirePw} />
          {requirePw && (
            <div className="pl-7 pb-1">
              <input
                value={password}
                onChange={e => setPassword(e.target.value)}
                placeholder="Meeting password"
                className="w-full h-8 rounded-lg border border-border bg-card px-3 text-sm text-foreground focus:outline-none focus:border-violet-400 transition-colors"
              />
            </div>
          )}
          <CheckRow label="Allow participants to join before host" checked={joinBefore} onChange={setJoinBefore} />

          <div className="border-t border-border my-3" />

          {/* Chat & Sharing */}
          <SectionLabel>
            <span className="flex items-center gap-1.5"><MessageSquare className="w-3 h-3" /> Chat & Sharing</span>
          </SectionLabel>
          <SelectRow label="Chat permissions" value={chatPerm} options={["Everyone", "Host Only", "Disabled"]} onChange={setChatPerm} />
          <SelectRow label="Screen sharing" value={sharePerm} options={["Host Only", "Everyone", "Request to Share"]} onChange={setSharePerm} />
          <SelectRow label="Share takeover" value={takeover} options={["One at a Time", "Host Can Take Over", "Anyone Can Take Over"]} onChange={setTakeover} />

          <div className="border-t border-border my-3" />

          {/* Recording — Pro-gated */}
          <SectionLabel>
            <span className="flex items-center gap-1.5"><Cloud className="w-3 h-3" /> Recording & Transcription</span>
          </SectionLabel>
          <div className="rounded-xl border border-amber-200 dark:border-amber-800/40 bg-amber-50 dark:bg-amber-900/10 p-3 mb-2">
            <div className="text-xs font-semibold text-amber-700 dark:text-amber-400">✦ Requires Pro or Pro+ subscription</div>
            <div className="text-[11px] text-amber-600 dark:text-amber-500 mt-0.5">Upgrade to unlock cloud recording and transcription.</div>
          </div>
          <div className="opacity-50 pointer-events-none space-y-0.5">
            <CheckRow label="Auto-record to cloud" checked={autoRecord} onChange={setAutoRecord} />
            <CheckRow label="Auto-transcript" checked={autoTranscript} onChange={setAutoTranscript} />
            <CheckRow label="Allow co-host local recording" checked={cohostRec} onChange={setCohostRec} />
          </div>
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t border-border flex justify-end gap-3 bg-muted">
          <button className="h-9 px-5 rounded-lg text-sm font-medium text-muted-foreground hover:bg-secondary transition-colors">Cancel</button>
          <button className="h-9 px-6 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors shadow-sm flex items-center gap-2">
            Save &amp; Start Meeting <kbd className="text-[10px] bg-violet-500/50 px-1 rounded font-mono">⏎</kbd>
          </button>
        </div>
      </div>
      )}
    </div>
  );
}
