import React, { useState } from "react";
import { Plus, Hash, MoreHorizontal, ChevronRight } from "lucide-react";

const TEAMS = [
  { id: 1, name: "Platform",      color: "bg-violet-500",    members: ["AM","BC","DK","EL"], total: 12, channels: 8,  active: true  },
  { id: 2, name: "Design Ops",    color: "bg-purple-500",  members: ["FG","HI"],           total: 8,  channels: 5,  active: false },
  { id: 3, name: "Hiring Panel",  color: "bg-emerald-500", members: ["JK","LM","NO"],      total: 5,  channels: 3,  active: true  },
];

const CHANNELS = [
  { name: "general",      unread: 4 },
  { name: "engineering",  unread: 0 },
  { name: "announcements",unread: 1 },
];

export function TeamsMock() {
  const [selected, setSelected] = useState(1);
  const team = TEAMS.find(t => t.id === selected)!;

  return (
    <div className="w-[760px] font-sans">
      <div className="bg-card rounded-xl border border-border shadow-xl overflow-hidden flex" style={{ height: 460 }}>

        {/* Left — team list */}
        <div className="w-56 flex-shrink-0 border-r border-border flex flex-col bg-muted">
          <div className="h-12 px-4 flex items-center justify-between border-b border-border">
            <span className="text-sm font-semibold">Teams</span>
            <button className="w-7 h-7 rounded-md flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors">
              <Plus className="w-4 h-4" />
            </button>
          </div>
          <div className="flex-1 overflow-y-auto p-2 space-y-1">
            {TEAMS.map((t) => (
              <button
                key={t.id}
                onClick={() => setSelected(t.id)}
                className={`w-full flex items-center gap-2.5 px-2.5 py-2.5 rounded-xl text-left transition-colors ${
                  selected === t.id
                    ? "bg-violet-50 dark:bg-violet-900/20 border border-violet-100 dark:border-violet-800/30"
                    : "hover:bg-accent border border-transparent"
                }`}
              >
                <div className={`w-8 h-8 rounded-lg ${t.color} flex items-center justify-center text-white text-xs font-bold flex-shrink-0`}>
                  {t.name.slice(0,2)}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="text-xs font-semibold text-foreground truncate">{t.name}</div>
                  <div className="text-[10px] text-muted-foreground">{t.total} members</div>
                </div>
                {!t.active && <span className="w-2 h-2 rounded-full bg-secondary flex-shrink-0" />}
              </button>
            ))}
          </div>
          <div className="p-3 border-t border-border">
            <button className="w-full flex items-center justify-center gap-1.5 text-xs font-semibold text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-900/20 rounded-lg py-2 transition-colors">
              <Plus className="w-3.5 h-3.5" /> Create or join a team
            </button>
          </div>
        </div>

        {/* Right — channel list + header */}
        <div className="flex-1 flex flex-col">
          <div className="h-12 px-5 flex items-center justify-between border-b border-border bg-card">
            <div className="flex items-center gap-2.5">
              <div className={`w-7 h-7 rounded-lg ${team.color} flex items-center justify-center text-white text-xs font-bold`}>
                {team.name.slice(0,2)}
              </div>
              <span className="font-semibold text-sm">{team.name}</span>
              <span className={`text-[10px] font-semibold px-1.5 py-0.5 rounded-full ${team.active ? "bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-400" : "bg-secondary text-muted-foreground"}`}>
                {team.active ? "Active" : "Archived"}
              </span>
            </div>
            <button className="w-7 h-7 rounded-md flex items-center justify-center text-neutral-500 hover:bg-accent transition-colors">
              <MoreHorizontal className="w-4 h-4" />
            </button>
          </div>

          <div className="px-5 py-3 border-b border-border flex items-center gap-3">
            <div className="flex -space-x-2">
              {team.members.map((m,i) => (
                <div key={i} className="w-7 h-7 rounded-full bg-muted border-2 border-white dark:border-neutral-900 flex items-center justify-center text-[10px] font-bold text-foreground">
                  {m}
                </div>
              ))}
              {team.total > team.members.length && (
                <div className="w-7 h-7 rounded-full bg-muted border-2 border-white dark:border-neutral-900 flex items-center justify-center text-[10px] font-bold text-muted-foreground">
                  +{team.total - team.members.length}
                </div>
              )}
            </div>
            <span className="text-xs text-muted-foreground">{team.total} members · {team.channels} channels</span>
            <button className="ml-auto text-xs font-semibold text-violet-600 dark:text-violet-400 hover:underline">Manage members</button>
          </div>

          <div className="flex-1 overflow-y-auto">
            <div className="px-5 pt-4 pb-1.5">
              <span className="text-[11px] font-semibold text-muted-foreground uppercase tracking-wide">Channels</span>
            </div>
            {CHANNELS.map((ch) => (
              <button key={ch.name} className="w-full flex items-center gap-2.5 px-5 py-2.5 text-left hover:bg-muted transition-colors group">
                <Hash className="w-4 h-4 text-neutral-400 flex-shrink-0" />
                <span className={`text-sm flex-1 ${ch.unread > 0 ? "font-semibold text-foreground" : "text-muted-foreground"}`}>
                  {ch.name}
                </span>
                {ch.unread > 0 && (
                  <span className="h-5 min-w-[20px] px-1.5 rounded-full bg-violet-600 text-white text-[10px] font-bold flex items-center justify-center">
                    {ch.unread}
                  </span>
                )}
                <ChevronRight className="w-3.5 h-3.5 text-neutral-300 opacity-0 group-hover:opacity-100 transition-opacity" />
              </button>
            ))}
            <button className="w-full flex items-center gap-2.5 px-5 py-2.5 text-left text-muted-foreground hover:text-foreground hover:bg-muted transition-colors">
              <Plus className="w-4 h-4" /><span className="text-sm">Add channel</span>
            </button>
          </div>

          <div className="px-5 py-3 border-t border-border flex gap-2 bg-muted">
            <button className="flex-1 h-8 rounded-lg border border-border text-xs font-semibold text-muted-foreground hover:bg-accent transition-colors">Settings</button>
            <button className="flex-1 h-8 rounded-lg bg-violet-600 hover:bg-violet-700 text-white text-xs font-semibold transition-colors">Open team</button>
          </div>
        </div>
      </div>
    </div>
  );
}
