import React, { useState } from "react";
import { SFSymbol } from "../ui/SFSymbol";
import { ChevronDown, X } from "lucide-react";

function DeviceRow({ sfName, sfOff, label, device, on, onToggle }: {
  sfName: string; sfOff: string; label: string; device: string; on: boolean; onToggle: () => void;
}) {
  return (
    <div className="flex items-center gap-3 px-4 py-2.5 bg-neutral-800/50 rounded-lg">
      <button onClick={onToggle} className={`w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0 transition-colors ${on ? "bg-neutral-700 text-white hover:bg-neutral-600" : "bg-red-500 text-white hover:bg-red-600"}`}>
        <SFSymbol name={on ? sfName : sfOff} size={16} weight="medium" />
      </button>
      <div className="flex-1 min-w-0">
        <div className="text-[11px] text-neutral-500 leading-none mb-0.5">{label}</div>
        <div className="text-xs text-neutral-200 truncate">{device}</div>
      </div>
      <button className="flex items-center gap-1 text-[11px] text-neutral-400 hover:text-neutral-200 flex-shrink-0 transition-colors">
        <span className="hidden sm:block">Change</span>
        <SFSymbol name="chevron.up" size={11} />
      </button>
    </div>
  );
}

/* Inline mini settings overlay — represents the "Meeting Settings" sheet */
function MeetingSettingsOverlay({ onClose }: { onClose: () => void }) {
  const [waitingRoom,  setWaitingRoom]  = useState(true);
  const [muteMic,      setMuteMic]      = useState(false);
  const [camOff,       setCamOff]       = useState(false);
  const [allowUnmute,  setAllowUnmute]  = useState(true);
  const [chatPerm,     setChatPerm]     = useState("Everyone");

  function CheckRow({ label, checked, onChange }: { label: string; checked: boolean; onChange: (v: boolean) => void }) {
    return (
      <label onClick={() => onChange(!checked)} className="flex items-center gap-2.5 py-1.5 cursor-pointer">
        <div className={`w-4 h-4 rounded flex items-center justify-center border flex-shrink-0 transition-colors ${checked ? "bg-violet-500 border-violet-500" : "border-white/30"}`}>
          {checked && <svg width="9" height="7" viewBox="0 0 9 7" fill="none"><path d="M1 3.5L3.5 6L8 1" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>}
        </div>
        <span className="text-xs text-neutral-300">{label}</span>
      </label>
    );
  }

  return (
    <div className="absolute inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center rounded-2xl">
      <div className="w-[340px] bg-[var(--stage-elevated)] rounded-2xl border border-white/10 shadow-2xl overflow-hidden">
        <div className="flex items-center justify-between px-5 py-4 border-b border-white/5">
          <span className="text-sm font-semibold text-white">Meeting Settings</span>
          <button onClick={onClose} className="w-6 h-6 rounded-md flex items-center justify-center text-neutral-500 hover:bg-white/10 hover:text-neutral-200 transition-colors">
            <X className="w-3.5 h-3.5" />
          </button>
        </div>
        <div className="px-5 py-4 space-y-1">
          <p className="text-[10px] font-bold uppercase tracking-widest text-neutral-500 mb-2">Participants</p>
          <CheckRow label="Mute mic after joining"         checked={muteMic}     onChange={setMuteMic} />
          <CheckRow label="Turn off camera after joining"  checked={camOff}      onChange={setCamOff} />
          <CheckRow label="Allow unmuting"                 checked={allowUnmute} onChange={setAllowUnmute} />

          <div className="border-t border-white/5 pt-3 mt-3" />
          <p className="text-[10px] font-bold uppercase tracking-widest text-neutral-500 mb-2">Security</p>
          <CheckRow label="Enable waiting room (Lobby)" checked={waitingRoom} onChange={setWaitingRoom} />

          <div className="border-t border-white/5 pt-3 mt-3" />
          <p className="text-[10px] font-bold uppercase tracking-widest text-neutral-500 mb-2">Chat</p>
          <div className="flex items-center justify-between py-1.5">
            <span className="text-xs text-neutral-300">Chat permissions</span>
            <div className="relative">
              <select value={chatPerm} onChange={e => setChatPerm(e.target.value)}
                className="appearance-none bg-white/10 text-neutral-200 text-xs rounded-md pl-2.5 pr-6 py-1 border border-white/10 focus:outline-none cursor-pointer">
                <option>Everyone</option>
                <option>Host Only</option>
                <option>Disabled</option>
              </select>
              <ChevronDown className="w-3 h-3 absolute right-1.5 top-1/2 -translate-y-1/2 text-neutral-400 pointer-events-none" />
            </div>
          </div>
        </div>
        <div className="px-5 py-4 border-t border-white/5 flex gap-2">
          <button onClick={onClose} className="flex-1 h-8 rounded-lg border border-white/10 text-xs font-medium text-neutral-400 hover:bg-white/10 transition-colors">Discard</button>
          <button onClick={onClose} className="flex-1 h-8 rounded-lg bg-violet-600 hover:bg-violet-700 text-white text-xs font-semibold transition-colors">Save Changes</button>
        </div>
      </div>
    </div>
  );
}

export function GreenRoomMock() {
  const [micOn, setMicOn]           = useState(true);
  const [camOn, setCamOn]           = useState(true);
  const [blur, setBlur]             = useState(false);
  const [name, setName]             = useState("Aman");
  const [showSettings, setShowSettings] = useState(false);

  return (
    <div className="w-[780px] font-sans">
      <div className="relative rounded-2xl overflow-hidden bg-[var(--stage-surface)] border border-white/10 shadow-2xl">
        {/* macOS titlebar */}
        <div className="h-10 flex items-center px-4 gap-2 bg-black/30 border-b border-white/5">
          <span className="w-3 h-3 rounded-full bg-red-400" />
          <span className="w-3 h-3 rounded-full bg-amber-400" />
          <span className="w-3 h-3 rounded-full bg-green-400" />
          <span className="mx-auto text-[11px] text-neutral-500 select-none">Green Room — Check your camera & mic</span>
          <div className="flex items-center gap-1 text-[11px] text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded-md">
            <SFSymbol name="shield.fill" size={11} className="text-emerald-400" /> Encrypted
          </div>
        </div>

        <div className="grid grid-cols-[1fr_280px]">
          {/* Left — camera preview */}
          <div className="relative bg-neutral-900 flex items-center justify-center" style={{ minHeight: 340 }}>
            <div className={`absolute inset-0 bg-gradient-to-br from-neutral-800 to-neutral-950 flex items-center justify-center ${blur ? "backdrop-blur-sm" : ""}`}>
              {camOn ? (
                <div className="w-24 h-24 rounded-full bg-neutral-700 flex items-center justify-center text-4xl font-semibold text-neutral-200 select-none">AM</div>
              ) : (
                <div className="flex flex-col items-center gap-2 text-neutral-600">
                  <SFSymbol name="video.slash.fill" size={32} />
                  <span className="text-sm select-none">Camera is off</span>
                </div>
              )}
            </div>
            {/* Name overlay */}
            <div className="absolute bottom-0 inset-x-0 bg-gradient-to-t from-black/80 to-transparent px-4 py-3">
              <input value={name} onChange={e => setName(e.target.value)}
                className="bg-transparent text-white text-sm font-semibold border-b border-white/30 focus:border-white focus:outline-none w-full"
                placeholder="Your name" />
            </div>
            <button onClick={() => setBlur(!blur)}
              className={`absolute top-3 right-3 text-[11px] px-2.5 py-1 rounded-md font-medium transition-colors ${blur ? "bg-violet-600 text-white" : "bg-black/50 text-neutral-300 hover:bg-black/70"}`}>
              Blur bg
            </button>
          </div>

          {/* Right — device controls */}
          <div className="border-l border-white/5 flex flex-col bg-[var(--stage-surface)]">
            <div className="p-4 space-y-2 flex-1">
              <p className="text-[11px] font-semibold text-neutral-500 uppercase tracking-wide mb-3">Audio & Video</p>
              <DeviceRow sfName="mic.fill"     sfOff="mic.slash.fill"    label="Microphone" device="MacBook Air Microphone" on={micOn} onToggle={() => setMicOn(!micOn)} />
              <DeviceRow sfName="video.fill"   sfOff="video.slash.fill"  label="Camera"     device="FaceTime HD Camera"    on={camOn} onToggle={() => setCamOn(!camOn)} />
              <DeviceRow sfName="speaker.wave.2.fill" sfOff="speaker.slash" label="Speaker" device="MacBook Air Speakers" on={true}  onToggle={() => {}} />
              <button className="text-[11px] text-violet-400 hover:text-violet-300 transition-colors mt-1">Test speaker & microphone…</button>
              <div className="pt-3 border-t border-white/5 space-y-2">
                <p className="text-[11px] font-semibold text-neutral-500 uppercase tracking-wide">Session</p>
                <div className="font-mono text-sm text-neutral-200 bg-neutral-800 rounded-md px-3 py-2 tracking-widest">A 9 2 K 1 Z</div>
                <div className="flex items-center gap-2">
                  <div className="w-2 h-2 rounded-full bg-emerald-500" />
                  <span className="text-[11px] text-neutral-400">Network quality: Excellent</span>
                </div>
              </div>
            </div>
            <div className="p-4 border-t border-white/5 space-y-2">
              {/* Meeting Settings button — visible to returning users */}
              <button
                onClick={() => setShowSettings(true)}
                className="w-full h-8 rounded-lg border border-white/10 text-[11px] font-semibold text-neutral-400 hover:bg-white/8 hover:text-neutral-200 transition-colors flex items-center justify-center gap-1.5"
              >
                <SFSymbol name="gearshape" size={11} />
                Meeting Settings
              </button>
              <button className="w-full h-10 rounded-lg bg-violet-600 hover:bg-violet-700 text-white text-sm font-semibold transition-colors shadow-lg shadow-violet-600/20">
                Join Now
              </button>
              <button className="w-full text-[11px] text-neutral-500 hover:text-neutral-300 transition-colors">
                Join without video
              </button>
            </div>
          </div>
        </div>

        {/* Meeting Settings overlay */}
        {showSettings && <MeetingSettingsOverlay onClose={() => setShowSettings(false)} />}
      </div>
    </div>
  );
}
