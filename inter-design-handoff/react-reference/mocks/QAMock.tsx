import React, { useState } from "react";
import { ThumbsUp, Mic, X, Pin, CheckCircle2 } from "lucide-react";

type QTab = "Open" | "Answered" | "Dismissed";
type QItem = {
  id: number; q: string; votes: number; tab: QTab;
  anonymous?: boolean; answer?: string;
  highlighted?: boolean; answered?: boolean;
};

export function QAMock() {
  const [tab, setTab]         = useState<QTab>("Open");
  const [votes, setVotes]     = useState<Record<number,boolean>>({});
  const [newQ, setNewQ]       = useState("");
  const [anon, setAnon]       = useState(false);
  const [items, setItems]     = useState<QItem[]>([
    { id: 1, q: "How will retries work on unstable networks?", votes: 18, tab: "Open",     anonymous: false },
    { id: 2, q: "Can hosts export attendance logs?",           votes: 11, tab: "Answered", answer: "Yes — available from Reports in account settings.", answered: true },
    { id: 3, q: "Will recording have role-based access?",      votes: 7,  tab: "Open",     anonymous: true  },
    { id: 4, q: "Is there a mobile app planned?",              votes: 4,  tab: "Open",     anonymous: false },
    { id: 5, q: "What's the max participant count per call?",  votes: 3,  tab: "Dismissed" },
  ]);

  const visible = items.filter(q => q.tab === tab);
  const update  = (id: number, patch: Partial<QItem>) =>
    setItems(is => is.map(i => i.id === id ? { ...i, ...patch } : i));
  const dismiss = (id: number) => update(id, { tab: "Dismissed" });
  const markAnswered = (id: number) => update(id, { tab: "Answered", answered: true });
  const highlight = (id: number, h: boolean) => update(id, { highlighted: h });

  const submitQ = () => {
    if (!newQ.trim()) return;
    setItems(is => [...is, { id: Date.now(), q: newQ, votes: 0, tab: "Open", anonymous: anon }]);
    setNewQ("");
  };

  return (
    <div className="w-[680px] font-sans">
      <div className="bg-card rounded-xl border border-border shadow-xl overflow-hidden">
        {/* Header */}
        <div className="h-12 px-5 flex items-center justify-between border-b border-border bg-muted">
          <span className="font-semibold text-sm text-foreground">Q&amp;A</span>
          <div className="flex items-center gap-2">
            <span className="text-[11px] text-muted-foreground">Open for questions</span>
            <div className="w-8 h-5 rounded-full bg-violet-600 flex items-center justify-end px-0.5">
              <span className="w-4 h-4 bg-white rounded-full shadow" />
            </div>
          </div>
        </div>

        {/* Tab strip — Open | Answered | Dismissed */}
        <div className="flex border-b border-border">
          {(["Open", "Answered", "Dismissed"] as QTab[]).map((t) => {
            const count = items.filter(q => q.tab === t).length;
            return (
              <button key={t} onClick={() => setTab(t)}
                className={`flex-1 py-2 text-xs font-semibold transition-colors flex items-center justify-center gap-1.5 ${
                  tab === t ? "border-b-2 border-violet-600 text-violet-600" : "text-muted-foreground hover:text-foreground"
                }`}
              >
                {t}
                <span className={`text-[10px] h-4 min-w-[16px] px-1 rounded-full font-semibold flex items-center justify-center ${tab === t ? "bg-violet-100 dark:bg-violet-900/40 text-violet-700 dark:text-violet-300" : "bg-secondary text-muted-foreground"}`}>
                  {count}
                </span>
              </button>
            );
          })}
        </div>

        {/* Question input — "Ask a question…" + Anonymous checkbox + Ask button (inventory §8) */}
        <div className="px-4 pt-3 pb-2 border-b border-border flex gap-2 items-center">
          <input
            value={newQ} onChange={e => setNewQ(e.target.value)}
            onKeyDown={e => e.key === "Enter" && submitQ()}
            placeholder="Ask a question…"
            className="flex-1 h-8 rounded-lg border border-border bg-card px-3 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:border-violet-400 transition-colors"
          />
          <label className="flex items-center gap-1.5 text-xs text-muted-foreground cursor-pointer flex-shrink-0">
            <input type="checkbox" checked={anon} onChange={e => setAnon(e.target.checked)} className="rounded" />
            Anonymous
          </label>
          <button onClick={submitQ} disabled={!newQ.trim()}
            className={`h-8 px-3 rounded-lg text-xs font-semibold transition-colors flex-shrink-0 ${newQ.trim() ? "bg-violet-600 hover:bg-violet-700 text-white" : "bg-secondary text-muted-foreground cursor-not-allowed"}`}>
            Ask
          </button>
        </div>

        {/* Questions — with row tinting per inventory §8 */}
        <div className="p-4 space-y-2 max-h-72 overflow-y-auto">
          {visible.length === 0 && (
            <div className="py-8 text-center text-sm text-muted-foreground">No questions in this tab.</div>
          )}
          {visible.map((item) => (
            <div key={item.id} className={`rounded-xl border p-3.5 space-y-2 transition-colors ${
              item.highlighted ? "border-violet-300 dark:border-violet-700 bg-violet-50 dark:bg-violet-900/15"   // Highlighted = blue tint
              : item.answered  ? "border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-900/15" // Answered = green tint
              : "border-border bg-card"
            }`}>
              <div className="flex items-start gap-3">
                <div className="flex-1 min-w-0">
                  {item.anonymous && (
                    <span className="text-[10px] font-bold text-muted-foreground uppercase tracking-wide block mb-1">Anonymous</span>
                  )}
                  <p className="text-sm text-foreground leading-relaxed">{item.q}</p>
                  {item.answer && (
                    <div className="mt-2 flex items-start gap-2 text-xs text-emerald-700 dark:text-emerald-400 bg-emerald-100 dark:bg-emerald-900/30 rounded-lg p-2 border border-emerald-200 dark:border-emerald-800/30">
                      <CheckCircle2 className="w-3.5 h-3.5 mt-0.5 flex-shrink-0" />
                      <span>{item.answer}</span>
                    </div>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-2 flex-wrap">
                {/* ▲ N Upvote — blue when already voted (disabled), gray otherwise */}
                <button
                  onClick={() => setVotes(v => ({ ...v, [item.id]: !v[item.id] }))}
                  className={`flex items-center gap-1.5 text-xs font-semibold px-2.5 py-1 rounded-full transition-colors ${
                    votes[item.id]
                      ? "bg-violet-600 text-white cursor-default"
                      : "bg-muted text-muted-foreground hover:bg-secondary"
                  }`}
                >
                  ▲ {item.votes + (votes[item.id] ? 1 : 0)}
                </button>

                {item.tab === "Open" && (
                  <>
                    {/* 📌 Highlight — host action, turns blue */}
                    <button onClick={() => highlight(item.id, !item.highlighted)}
                      className={`flex items-center gap-1 text-xs font-semibold px-2.5 py-1 rounded-full border transition-colors ${
                        item.highlighted
                          ? "bg-violet-100 dark:bg-violet-900/30 text-violet-700 dark:text-violet-300 border-violet-200 dark:border-violet-800"
                          : "border-border text-muted-foreground hover:bg-secondary"
                      }`}
                      title="Highlight (host)">
                      <Pin className="w-3 h-3" /> {item.highlighted ? "Highlighted" : "Highlight"}
                    </button>
                    {/* ✅ Mark Answered — host action */}
                    <button onClick={() => markAnswered(item.id)}
                      className="flex items-center gap-1 text-xs font-semibold text-muted-foreground border border-border rounded-full px-2.5 py-1 hover:bg-secondary transition-colors"
                      title="Mark Answered (host)">
                      <CheckCircle2 className="w-3 h-3" /> Mark Answered
                    </button>
                    {/* Answer live */}
                    <button className="flex items-center gap-1.5 text-xs font-semibold text-muted-foreground border border-border rounded-full px-2.5 py-1 hover:bg-secondary transition-colors">
                      <Mic className="w-3 h-3" /> Answer live
                    </button>
                    {/* ✕ Dismiss — host, red */}
                    <button onClick={() => dismiss(item.id)}
                      className="ml-auto text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-full p-1 transition-colors"
                      title="Dismiss (host)">
                      <X className="w-4 h-4" />
                    </button>
                  </>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
