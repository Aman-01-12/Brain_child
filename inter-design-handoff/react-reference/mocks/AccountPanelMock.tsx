import React, { useState } from "react";
import {
  User, Video, Mic, Image, Shield, ChevronDown, Check, Edit2,
  Key, Mail, Monitor, Settings2, AlertTriangle, RefreshCw, Trash2,
} from "lucide-react";

type Tab = "Profile" | "Meeting Defaults" | "Video" | "Audio" | "Background" | "Security" | "Password" | "Email" | "Sessions";

const TABS: { id: Tab; icon: React.ReactNode; group?: string }[] = [
  { id: "Profile",          icon: <User className="w-3.5 h-3.5" />,     group: "Account"   },
  { id: "Password",         icon: <Key className="w-3.5 h-3.5" />,      group: "Account"   },
  { id: "Email",            icon: <Mail className="w-3.5 h-3.5" />,     group: "Account"   },
  { id: "Sessions",         icon: <Monitor className="w-3.5 h-3.5" />,  group: "Account"   },
  { id: "Meeting Defaults", icon: <Settings2 className="w-3.5 h-3.5" />, group: "Meetings" },
  { id: "Video",            icon: <Video className="w-3.5 h-3.5" />,    group: "Meetings"  },
  { id: "Audio",            icon: <Mic className="w-3.5 h-3.5" />,      group: "Meetings"  },
  { id: "Background",       icon: <Image className="w-3.5 h-3.5" />,    group: "Meetings"  },
  { id: "Security",         icon: <Shield className="w-3.5 h-3.5" />,   group: "Meetings"  },
];

function DeviceDropdown({ label, value }: { label: string; value: string }) {
  return (
    <div className="space-y-1.5">
      <label className="text-xs font-medium text-muted-foreground">{label}</label>
      <button className="w-full flex items-center justify-between h-9 border border-border rounded-lg px-3 bg-card text-sm text-foreground hover:border-violet-400 transition-colors">
        <span className="truncate">{value}</span>
        <ChevronDown className="w-4 h-4 text-muted-foreground flex-shrink-0 ml-2" />
      </button>
    </div>
  );
}

function Toggle({ label, hint, defaultOn }: { label: string; hint?: string; defaultOn?: boolean }) {
  const [on, setOn] = useState(defaultOn ?? false);
  return (
    <div className="flex items-start justify-between gap-4 py-2.5 border-b border-border last:border-0">
      <div className="flex-1">
        <div className="text-sm font-medium text-foreground">{label}</div>
        {hint && <div className="text-xs text-muted-foreground mt-0.5">{hint}</div>}
      </div>
      <button onClick={() => setOn(!on)} className={`relative flex-shrink-0 w-10 h-6 rounded-full transition-colors ${on ? "bg-violet-600" : "bg-secondary"}`}>
        <span className={`absolute top-1 w-4 h-4 bg-white rounded-full shadow transition-transform ${on ? "translate-x-5" : "translate-x-1"}`} />
      </button>
    </div>
  );
}

function SelectRow({ label, value, options, onChange }: { label: string; value: string; options: string[]; onChange: (v: string) => void }) {
  return (
    <div className="flex items-center justify-between py-2 border-b border-border last:border-0">
      <div className="text-sm text-foreground">{label}</div>
      <div className="relative">
        <select value={value} onChange={e => onChange(e.target.value)}
          className="appearance-none h-8 pl-3 pr-7 rounded-lg border border-border bg-card text-sm text-foreground focus:outline-none focus:border-violet-400 cursor-pointer">
          {options.map(o => <option key={o}>{o}</option>)}
        </select>
        <ChevronDown className="w-3.5 h-3.5 absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none" />
      </div>
    </div>
  );
}

function PwField({ label, placeholder }: { label: string; placeholder: string }) {
  return (
    <div className="space-y-1.5">
      <label className="text-xs font-medium text-muted-foreground">{label}</label>
      <input type="password" placeholder={placeholder}
        className="w-full h-9 border border-border rounded-lg px-3 text-sm bg-card text-foreground placeholder:text-muted-foreground focus:outline-none focus:border-violet-400 transition-colors" />
    </div>
  );
}

const SESSIONS = [
  { device: "a3f9e2b1",   started: "Jun 8, 10:12 AM", lastUsed: "Just now",     current: true  },
  { device: "7c82d4e0",   started: "Jun 7, 4:31 PM",  lastUsed: "Jun 8, 8:00 AM", current: false },
  { device: "f1b3902c",   started: "Jun 5, 9:00 AM",  lastUsed: "Jun 5, 9:45 AM", current: false },
];

export function AccountPanelMock() {
  const [tab, setTab] = useState<Tab>("Profile");
  const [editingName, setEditingName] = useState(false);
  const [pwStatus, setPwStatus] = useState<"idle" | "saving" | "done">("idle");
  const [emailStatus, setEmailStatus] = useState<"idle" | "saving" | "done">("idle");

  // Meeting defaults state
  const [muteMicAfter,  setMuteMicAfter]  = useState(false);
  const [camOffAfter,   setCamOffAfter]   = useState(false);
  const [allowUnmuting, setAllowUnmuting] = useState(true);
  const [waitingRoom,   setWaitingRoom]   = useState(true);
  const [requirePw,     setRequirePw]     = useState(false);
  const [joinBefore,    setJoinBefore]    = useState(false);
  const [chatPerm,      setChatPerm]      = useState("Everyone");
  const [sharePerm,     setSharePerm]     = useState("Host Only");
  const [takeover,      setTakeover]      = useState("One at a Time");
  const [autoRecord,    setAutoRecord]    = useState(false);
  const [autoTranscript,setAutoTranscript]= useState(false);
  const [cohostRec,     setCohostRec]     = useState(false);

  const groups = Array.from(new Set(TABS.map(t => t.group)));

  return (
    <div className="w-[820px] bg-card rounded-2xl border border-border shadow-xl overflow-hidden font-sans flex" style={{ height: 540 }}>

      {/* ── Sidebar nav ── */}
      <div className="w-48 flex-shrink-0 border-r border-border bg-muted py-3 flex flex-col">
        {/* Avatar */}
        <div className="px-4 pb-3 mb-1 border-b border-border">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-full bg-violet-500 flex items-center justify-center text-sm font-bold text-white flex-shrink-0">AM</div>
            <div className="min-w-0">
              <div className="text-xs font-semibold text-foreground truncate">Aman</div>
              <div className="text-[10px] text-muted-foreground truncate">aman@example.com</div>
            </div>
          </div>
        </div>
        {/* Group nav */}
        <div className="flex-1 overflow-y-auto px-2 space-y-3">
          {groups.map(g => (
            <div key={g}>
              <div className="text-[9px] font-bold uppercase tracking-widest text-muted-foreground px-2 py-1">{g}</div>
              {TABS.filter(t => t.group === g).map(({ id, icon }) => (
                <button key={id} onClick={() => setTab(id)}
                  className={`w-full flex items-center gap-2 px-2.5 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                    tab === id
                      ? "bg-background text-violet-600 font-semibold shadow-sm border border-border"
                      : "text-muted-foreground hover:bg-background/60 hover:text-foreground"
                  }`}>
                  {icon} {id}
                </button>
              ))}
            </div>
          ))}
        </div>
      </div>

      {/* ── Content panel ── */}
      <div className="flex-1 flex flex-col min-w-0">
        <div className="flex-shrink-0 h-11 border-b border-border flex items-center px-6 bg-card">
          <h2 className="text-sm font-semibold text-foreground">{tab}</h2>
        </div>

        <div className="flex-1 overflow-y-auto px-6 py-4">

          {/* ─── Profile ─── */}
          {tab === "Profile" && (
            <div className="space-y-5">
              <div className="flex items-center gap-4">
                <div className="w-16 h-16 rounded-full bg-violet-500 flex items-center justify-center text-2xl font-bold text-white flex-shrink-0">AM</div>
                <div>
                  {editingName ? (
                    <div className="flex items-center gap-2">
                      <input autoFocus defaultValue="Aman" className="border-b border-violet-400 bg-transparent text-lg font-semibold text-foreground focus:outline-none" />
                      <button onClick={() => setEditingName(false)} className="text-violet-600"><Check className="w-4 h-4" /></button>
                    </div>
                  ) : (
                    <div className="flex items-center gap-2">
                      <span className="text-lg font-semibold text-foreground">Aman</span>
                      <button onClick={() => setEditingName(true)} className="text-muted-foreground hover:text-foreground"><Edit2 className="w-3.5 h-3.5" /></button>
                    </div>
                  )}
                  <div className="font-mono text-sm text-muted-foreground">aman@example.com</div>
                  <div className="flex gap-2 mt-1.5">
                    <span className="text-[10px] bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300 px-2 py-0.5 rounded-full font-semibold">Plan: Pro</span>
                    <span className="text-[10px] bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300 px-2 py-0.5 rounded-full font-semibold">2FA On</span>
                  </div>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <DeviceDropdown label="Timezone" value="Asia/Kolkata (IST)" />
                <DeviceDropdown label="Language" value="English (US)" />
              </div>
              <div className="space-y-1.5">
                <label className="text-xs font-medium text-muted-foreground">Personal Meeting ID</label>
                <div className="flex items-center gap-2">
                  <div className="font-mono text-sm text-foreground bg-secondary rounded-lg px-3 h-9 flex items-center flex-1">283-748-2910</div>
                  <button className="text-[11px] font-semibold text-violet-600 border border-violet-200 dark:border-violet-800 rounded-lg px-3 h-9 hover:bg-violet-50 dark:hover:bg-violet-900/20 transition-colors">Copy link</button>
                </div>
              </div>
              <div className="flex justify-end pt-2 border-t border-border">
                <button className="px-5 py-2 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors">Save changes</button>
              </div>
            </div>
          )}

          {/* ─── Change Password ─── */}
          {tab === "Password" && (
            <div className="space-y-4 max-w-sm">
              <PwField label="Current password" placeholder="Current password" />
              <PwField label="New password (8–72 characters)" placeholder="New password" />
              <PwField label="Confirm new password" placeholder="Confirm new password" />
              <div className="flex items-center gap-3 pt-1">
                <button
                  onClick={() => { setPwStatus("saving"); setTimeout(() => setPwStatus("done"), 1200); }}
                  disabled={pwStatus === "saving"}
                  className="h-9 px-5 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors disabled:opacity-60">
                  {pwStatus === "saving" ? "Saving…" : "Change Password"}
                </button>
                {pwStatus === "done" && <span className="text-sm text-emerald-600 font-medium">✓ Password updated</span>}
              </div>
            </div>
          )}

          {/* ─── Change Email ─── */}
          {tab === "Email" && (
            <div className="space-y-4 max-w-sm">
              <PwField label="Confirm your current password" placeholder="Current password" />
              <div className="space-y-1.5">
                <label className="text-xs font-medium text-muted-foreground">New email address</label>
                <input type="email" placeholder="new@example.com"
                  className="w-full h-9 border border-border rounded-lg px-3 text-sm bg-card text-foreground placeholder:text-muted-foreground focus:outline-none focus:border-violet-400 transition-colors" />
              </div>
              <div className="flex items-center gap-3 pt-1">
                <button
                  onClick={() => { setEmailStatus("saving"); setTimeout(() => setEmailStatus("done"), 1200); }}
                  disabled={emailStatus === "saving"}
                  className="h-9 px-5 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors disabled:opacity-60">
                  {emailStatus === "saving" ? "Sending…" : "Send Verification"}
                </button>
                {emailStatus === "done" && <span className="text-sm text-emerald-600 font-medium">✓ Verification email sent</span>}
              </div>
            </div>
          )}

          {/* ─── Active Sessions ─── */}
          {tab === "Sessions" && (
            <div className="space-y-4">
              <div className="flex items-center gap-2">
                <button className="flex items-center gap-1.5 text-xs font-semibold text-violet-600 border border-violet-200 dark:border-violet-800 rounded-lg px-3 h-8 hover:bg-violet-50 dark:hover:bg-violet-900/20 transition-colors">
                  <RefreshCw className="w-3 h-3" /> Refresh
                </button>
              </div>
              <div className="rounded-xl border border-border overflow-hidden">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="bg-secondary text-muted-foreground text-xs font-semibold">
                      <th className="text-left px-4 py-2.5">Device</th>
                      <th className="text-left px-4 py-2.5">Started</th>
                      <th className="text-left px-4 py-2.5">Last Used</th>
                      <th className="text-left px-4 py-2.5">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {SESSIONS.map((s, i) => (
                      <tr key={i} className="border-t border-border hover:bg-muted/50 transition-colors">
                        <td className="px-4 py-2.5 font-mono text-xs text-foreground">{s.device}</td>
                        <td className="px-4 py-2.5 text-xs text-muted-foreground">{s.started}</td>
                        <td className="px-4 py-2.5 text-xs text-muted-foreground">{s.lastUsed}</td>
                        <td className="px-4 py-2.5">
                          {s.current
                            ? <span className="text-[11px] font-semibold text-emerald-600 bg-emerald-50 dark:bg-emerald-900/20 px-2 py-0.5 rounded-full">This Device</span>
                            : <button className="text-xs font-semibold text-red-500 hover:text-red-600 border border-red-200 dark:border-red-800/50 rounded-md px-2 py-0.5 hover:bg-red-50 dark:hover:bg-red-900/10 transition-colors">Revoke</button>
                          }
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {/* Danger Zone */}
              <div className="rounded-xl border border-red-200 dark:border-red-800/40 bg-red-50 dark:bg-red-900/10 p-4 mt-4">
                <div className="flex items-center gap-2 mb-2">
                  <AlertTriangle className="w-4 h-4 text-red-500" />
                  <span className="text-sm font-semibold text-red-600">Danger Zone</span>
                </div>
                <p className="text-xs text-red-600/80 dark:text-red-400 mb-3">Permanently deletes your account and all data. This cannot be undone.</p>
                <button className="flex items-center gap-2 h-8 px-4 rounded-lg text-xs font-semibold border border-red-300 dark:border-red-700 text-red-600 hover:bg-red-100 dark:hover:bg-red-900/20 transition-colors">
                  <Trash2 className="w-3.5 h-3.5" /> Delete Account…
                </button>
              </div>
            </div>
          )}

          {/* ─── Meeting Defaults ─── */}
          {tab === "Meeting Defaults" && (
            <div className="space-y-1 max-w-lg">
              <div className="text-xs text-muted-foreground mb-3 leading-relaxed">
                These settings become the defaults for every new meeting. They can still be adjusted per-meeting from the Green Room via "Meeting Settings".
              </div>
              <div className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground pb-1">Participants</div>
              <Toggle label="Mute mic after joining" />
              <Toggle label="Turn off camera after joining" />
              <Toggle label="Allow unmuting" defaultOn hint="Participants can unmute without host permission" />
              <div className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground pt-3 pb-1">Security</div>
              <Toggle label="Enable waiting room (Lobby)" defaultOn hint="Participants must be admitted by host" />
              <Toggle label="Require meeting password" />
              <Toggle label="Allow join before host" />
              <div className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground pt-3 pb-1">Chat & Sharing</div>
              <SelectRow label="Chat permissions" value={chatPerm} options={["Everyone","Host Only","Disabled"]} onChange={setChatPerm} />
              <SelectRow label="Screen sharing" value={sharePerm} options={["Host Only","Everyone","Request to Share"]} onChange={setSharePerm} />
              <SelectRow label="Share takeover" value={takeover} options={["One at a Time","Host Can Take Over","Anyone Can Take Over"]} onChange={setTakeover} />
              <div className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground pt-3 pb-1">Recording (Pro)</div>
              <div className="rounded-lg border border-amber-200 dark:border-amber-800/40 bg-amber-50 dark:bg-amber-900/10 px-3 py-2 text-[11px] text-amber-700 dark:text-amber-400 mb-2">✦ Requires Pro or Pro+ subscription</div>
              <div className="opacity-50 pointer-events-none">
                <Toggle label="Auto-record to cloud" />
                <Toggle label="Auto-transcript" />
                <Toggle label="Allow co-host local recording" />
              </div>
              <div className="flex justify-end pt-3 border-t border-border mt-3">
                <button className="px-5 py-2 rounded-lg text-sm font-semibold bg-violet-600 hover:bg-violet-700 text-white transition-colors">Save defaults</button>
              </div>
            </div>
          )}

          {/* ─── Video ─── */}
          {tab === "Video" && (
            <div className="space-y-4 max-w-lg">
              <DeviceDropdown label="Camera" value="FaceTime HD Camera (Built-in)" />
              <div className="rounded-lg border border-border bg-secondary h-32 flex items-center justify-center text-sm text-muted-foreground">Camera preview</div>
              <Toggle label="Always show video preview when joining" defaultOn />
              <Toggle label="Stop my video when joining a meeting" />
              <Toggle label="Touch up my appearance" hint="Applies subtle facial smoothing" />
              <Toggle label="Adjust for low light" hint="Automatically brightens your video" defaultOn />
              <Toggle label="Mirror my video" defaultOn />
            </div>
          )}

          {/* ─── Audio ─── */}
          {tab === "Audio" && (
            <div className="space-y-4 max-w-lg">
              <DeviceDropdown label="Speaker" value="MacBook Air Speakers" />
              <button className="text-sm text-violet-600 hover:underline">Test speaker</button>
              <DeviceDropdown label="Microphone" value="MacBook Air Microphone" />
              <button className="text-sm text-violet-600 hover:underline">Test microphone</button>
              <Toggle label="Automatically join audio by computer" defaultOn />
              <Toggle label="Mute my microphone when joining a meeting" />
              <Toggle label="Suppress background noise" defaultOn hint="AI-powered noise cancellation" />
            </div>
          )}

          {/* ─── Background ─── */}
          {tab === "Background" && (
            <div className="space-y-3 max-w-lg">
              <p className="text-sm text-muted-foreground">Choose a virtual background or blur.</p>
              <div className="grid grid-cols-4 gap-2">
                {["None","Blur","Office","Nature"].map((bg, i) => (
                  <div key={bg} className={`aspect-video rounded-lg flex items-center justify-center text-xs font-medium cursor-pointer transition-colors ${i === 0 ? "ring-2 ring-violet-500 bg-secondary" : "bg-secondary text-muted-foreground hover:ring-2 hover:ring-border"}`}>{bg}</div>
                ))}
              </div>
            </div>
          )}

          {/* ─── Security ─── */}
          {tab === "Security" && (
            <div className="space-y-0 max-w-lg">
              <Toggle label="Two-factor authentication" defaultOn hint="Recommended for account protection" />
              <Toggle label="Sign out from all devices on password change" />
              <Toggle label="Allow recordings only to verified devices" defaultOn />
            </div>
          )}

        </div>
      </div>
    </div>
  );
}
