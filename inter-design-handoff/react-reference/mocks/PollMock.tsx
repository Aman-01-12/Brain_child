import React, { useState } from "react";
import { BarChart2, Plus, Share2, Square, Trash2 } from "lucide-react";

type PollMode = "create" | "active" | "voting" | "results";

export function PollMock() {
  const [mode, setMode]       = useState<PollMode>("create");
  // Create mode state
  const [question, setQuestion] = useState("Should we launch the new onboarding flow next sprint?");
  const [options, setOptions]   = useState(["Yes, proceed with rollout", "Run another beta week first", "Pause and re-scope"]);
  const [anonVoting, setAnonVoting]   = useState(false);
  const [multiSelect, setMultiSelect] = useState(false);
  // Voting / results state
  const [selected, setSelected] = useState<number[]>([]);
  const [submitted, setSubmitted] = useState(false);
  const [shared, setShared]     = useState(false);

  const VOTES = [36, 20, 8];
  const TOTAL = 64;

  const addOption = () => {
    if (options.length < 10) setOptions(o => [...o, ""]);
  };
  const removeOption = (i: number) => setOptions(o => o.filter((_, idx) => idx !== i));

  const toggleSelect = (i: number) => {
    if (submitted) return;
    if (multiSelect) {
      setSelected(s => s.includes(i) ? s.filter(x => x !== i) : [...s, i]);
    } else {
      setSelected([i]);
    }
  };

  return (
    <div className="w-[680px] font-sans space-y-3">
      {/* Mode selector */}
      <div className="flex items-center gap-2 bg-card border border-border rounded-xl px-4 py-2.5">
        <span className="text-xs font-semibold text-muted-foreground mr-1">Mode:</span>
        {([
          { id: "create",  label: "Host — Create"   },
          { id: "active",  label: "Host — Active"   },
          { id: "voting",  label: "Participant Voting" },
          { id: "results", label: "Results"         },
        ] as { id: PollMode; label: string }[]).map(m => (
          <button key={m.id} onClick={() => { setMode(m.id); setSubmitted(false); setSelected([]); setShared(false); }}
            className={`px-2.5 py-1.5 rounded-lg text-xs font-semibold transition-colors ${mode === m.id ? "bg-violet-600 text-white" : "bg-secondary text-muted-foreground hover:bg-muted"}`}>
            {m.label}
          </button>
        ))}
      </div>

      <div className="bg-card rounded-xl border border-border shadow-xl overflow-hidden">
        {/* Header */}
        <div className="h-12 px-5 flex items-center justify-between border-b border-border bg-muted">
          <div className="flex items-center gap-2">
            <BarChart2 className="w-4 h-4 text-muted-foreground" />
            <span className="font-semibold text-sm text-foreground">Polls</span>
          </div>
          {mode === "active" && (
            <span className="flex items-center gap-1.5 text-[11px] font-semibold text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-800/30 px-2.5 py-1 rounded-full">
              <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse" /> Live · {TOTAL} responses
            </span>
          )}
        </div>

        <div className="p-5">

          {/* ── HOST CREATE MODE ── */}
          {mode === "create" && (
            <div className="space-y-4">
              <div className="space-y-1.5">
                <label className="text-xs font-semibold text-muted-foreground">Question</label>
                <input value={question} onChange={e => setQuestion(e.target.value)}
                  placeholder="Type your question here…"
                  className="w-full h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:border-violet-400 transition-colors" />
              </div>
              <div className="space-y-2">
                <label className="text-xs font-semibold text-muted-foreground">Options</label>
                {options.map((opt, i) => (
                  <div key={i} className="flex items-center gap-2">
                    <input value={opt} onChange={e => setOptions(o => o.map((x, idx) => idx === i ? e.target.value : x))}
                      placeholder={`Option ${i + 1}`}
                      className="flex-1 h-9 rounded-lg border border-border bg-card px-3 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:border-violet-400 transition-colors" />
                    {options.length > 2 && (
                      <button onClick={() => removeOption(i)} className="text-muted-foreground hover:text-red-500 transition-colors">
                        <Trash2 className="w-4 h-4" />
                      </button>
                    )}
                  </div>
                ))}
                {/* "+ Add Option" — disabled at 10 */}
                <button onClick={addOption} disabled={options.length >= 10}
                  className={`flex items-center gap-1.5 text-xs font-semibold transition-colors ${options.length >= 10 ? "text-muted-foreground cursor-not-allowed" : "text-violet-600 hover:underline"}`}>
                  <Plus className="w-3.5 h-3.5" /> Add Option {options.length >= 10 && "(max 10)"}
                </button>
              </div>
              <div className="space-y-2 border-t border-border pt-3">
                <label className="flex items-center gap-2.5 cursor-pointer">
                  <input type="checkbox" checked={anonVoting} onChange={e => setAnonVoting(e.target.checked)} className="rounded" />
                  <span className="text-sm text-foreground">Anonymous voting</span>
                </label>
                <label className="flex items-center gap-2.5 cursor-pointer">
                  <input type="checkbox" checked={multiSelect} onChange={e => setMultiSelect(e.target.checked)} className="rounded" />
                  <span className="text-sm text-foreground">Allow multiple selections</span>
                </label>
              </div>
              <button onClick={() => setMode("active")}
                className="w-full h-9 rounded-lg bg-violet-600 hover:bg-violet-700 text-white text-sm font-semibold transition-colors">
                Launch Poll
              </button>
            </div>
          )}

          {/* ── HOST ACTIVE MODE ── */}
          {mode === "active" && (
            <div className="space-y-3">
              <p className="text-sm font-semibold text-foreground">{question}</p>
              <div className="space-y-3">
                {options.map((opt, i) => {
                  const pct = Math.round((VOTES[i] ?? 0) / TOTAL * 100);
                  return (
                    <div key={i}>
                      <div className="flex items-center justify-between text-sm mb-1.5">
                        <span className="text-foreground">{opt}</span>
                        <span className="font-semibold text-foreground tabular-nums">{pct}%</span>
                      </div>
                      <div className="h-2.5 rounded-full bg-secondary overflow-hidden">
                        <div className="h-full rounded-full bg-violet-500 transition-all" style={{ width: `${pct}%` }} />
                      </div>
                      <div className="text-[10px] text-muted-foreground mt-0.5">{VOTES[i] ?? 0} votes</div>
                    </div>
                  );
                })}
              </div>
              <div className="flex gap-3 pt-2 border-t border-border">
                <button onClick={() => setMode("create")}
                  className="flex items-center gap-1.5 flex-1 justify-center h-9 rounded-lg border border-border text-sm font-semibold text-foreground hover:bg-muted transition-colors">
                  <Square className="w-3.5 h-3.5" /> End Poll
                </button>
                <button onClick={() => { setShared(true); }}
                  className={`flex items-center gap-1.5 flex-1 justify-center h-9 rounded-lg text-sm font-semibold transition-colors ${shared ? "bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800" : "bg-violet-600 hover:bg-violet-700 text-white"}`}>
                  <Share2 className="w-3.5 h-3.5" /> {shared ? "Results shared" : "Share Results"}
                </button>
              </div>
            </div>
          )}

          {/* ── PARTICIPANT VOTING MODE ── */}
          {mode === "voting" && (
            <div className="space-y-4">
              <p className="text-sm font-semibold text-foreground">{question}</p>
              {anonVoting && <p className="text-[11px] text-muted-foreground">Your vote is anonymous.</p>}
              <div className="space-y-2">
                {options.map((opt, i) => (
                  <button key={i} onClick={() => toggleSelect(i)} disabled={submitted}
                    className={`w-full flex items-center gap-3 px-4 py-3 rounded-xl border text-sm font-medium text-left transition-colors ${
                      selected.includes(i)
                        ? "border-violet-500 bg-violet-50 dark:bg-violet-900/20 text-violet-700 dark:text-violet-300"
                        : "border-border text-foreground hover:bg-muted"
                    }`}>
                    <div className={`w-4 h-4 rounded-${multiSelect ? "sm" : "full"} border-2 flex items-center justify-center flex-shrink-0 ${selected.includes(i) ? "border-violet-500 bg-violet-500" : "border-muted-foreground"}`}>
                      {selected.includes(i) && <div className={`bg-white rounded-${multiSelect ? "sm" : "full"} ${multiSelect ? "w-2 h-2" : "w-1.5 h-1.5"}`} />}
                    </div>
                    {opt}
                  </button>
                ))}
              </div>
              <button onClick={() => setSubmitted(true)} disabled={selected.length === 0 || submitted}
                className={`w-full h-9 rounded-lg text-sm font-semibold transition-colors ${submitted ? "bg-emerald-600 text-white cursor-default" : selected.length > 0 ? "bg-emerald-600 hover:bg-emerald-700 text-white" : "bg-secondary text-muted-foreground cursor-not-allowed"}`}>
                {submitted ? "Vote submitted ✓" : "Submit Vote"}
              </button>
            </div>
          )}

          {/* ── ALL — RESULTS MODE ── */}
          {mode === "results" && (
            <div className="space-y-3">
              <p className="text-sm font-semibold text-foreground">{question}</p>
              <div className="space-y-3">
                {options.map((opt, i) => {
                  const pct  = Math.round((VOTES[i] ?? 0) / TOTAL * 100);
                  const voted = i === 0; // simulate "You voted for this"
                  return (
                    <div key={i}>
                      <div className="flex items-center justify-between text-sm mb-1.5">
                        <span className={`${voted ? "font-semibold text-foreground" : "text-foreground"}`}>{opt}{voted && " ✓"}</span>
                        <span className="font-semibold text-foreground tabular-nums">{pct}%</span>
                      </div>
                      <div className="h-2.5 rounded-full bg-secondary overflow-hidden">
                        {/* Green if participant voted for it, blue otherwise */}
                        <div className={`h-full rounded-full transition-all ${voted ? "bg-emerald-500" : "bg-violet-500"}`} style={{ width: `${pct}%` }} />
                      </div>
                      <div className="text-[10px] text-muted-foreground mt-0.5">{VOTES[i] ?? 0} votes</div>
                    </div>
                  );
                })}
              </div>
              {/* "New Poll" — host action per inventory §9 */}
              <div className="pt-2 border-t border-border">
                <button onClick={() => setMode("create")}
                  className="flex items-center gap-1.5 text-xs font-semibold text-violet-600 dark:text-violet-400 hover:underline">
                  <Plus className="w-3.5 h-3.5" /> New Poll
                </button>
              </div>
            </div>
          )}

        </div>
      </div>
    </div>
  );
}
