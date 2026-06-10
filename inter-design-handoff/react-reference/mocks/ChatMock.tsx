import React, { useState } from "react";
import { Smile, Paperclip, Send, X, ChevronDown, Download, MoreHorizontal, Search, Share } from "lucide-react";
import { Avatar, AvatarFallback } from "../ui/avatar";

const MSGS = [
  { id: 1, type: "system", content: "Alice Chen joined the meeting." },
  { id: 2, sender: "Bob Smith", initial: "B", content: "Can everyone hear me clearly?", time: "10:05 AM", isMe: false },
  { id: 3, sender: "You", initial: "Y", content: "Yes, loud and clear!", time: "10:06 AM", isMe: true },
  { id: 4, sender: "Diana Prince", initial: "D", content: "Here's the design spec for the new features.", time: "10:12 AM", isMe: false, file: { name: "design_spec_v2.pdf", size: "2.4 MB" } },
  { id: 5, sender: "Alice Chen", initial: "A", content: "Just sent you the credentials over DM.", time: "10:15 AM", isMe: false, isDM: true },
];
const RECIPIENTS = ["Everyone", "Alice Chen", "Bob Smith", "Diana Prince"];
const REACTIONS = ["👍", "❤️", "😂", "😮", "😢"];

export function ChatMock() {
  const [input, setInput] = useState("");
  const [hovered, setHovered] = useState<number | null>(null);
  const [tab, setTab] = useState<"chat" | "polls">("chat");
  const [recipient, setRecipient] = useState("Everyone");

  return (
    <div className="w-[360px] h-[620px] flex flex-col bg-card border border-border shadow-2xl rounded-xl overflow-hidden font-sans">
      {/* Panel header — Export (Pro/host only) per inventory §5 */}
      <div className="flex-shrink-0 h-12 flex items-center justify-between px-4 bg-muted border-b border-border">
        <span className="font-semibold text-sm">Meeting Chat</span>
        <div className="flex items-center gap-0.5">
          {/* Export — share icon, Pro/host only */}
          <button className="w-7 h-7 rounded-md flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors" title="Export (Pro)">
            <Share className="w-4 h-4" />
          </button>
          {[<Search className="w-4 h-4" />, <MoreHorizontal className="w-4 h-4" />, <X className="w-4 h-4" />].map((ic, i) => (
            <button key={i} className="w-7 h-7 rounded-md flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors">
              {ic}
            </button>
          ))}
        </div>
      </div>

      {/* Tab strip — Chat | Polls */}
      <div className="flex-shrink-0 flex border-b border-border bg-card">
        {(["chat", "polls"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 py-2 text-xs font-semibold capitalize transition-colors ${
              tab === t
                ? "border-b-2 border-violet-600 text-violet-600"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            {t}
          </button>
        ))}
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-3 space-y-3 bg-card">
        {MSGS.map((m) => {
          if (m.type === "system") {
            return (
              <div key={m.id} className="flex justify-center">
                <span className="text-[11px] text-neutral-400 bg-secondary px-2.5 py-1 rounded-full">
                  {m.content}
                </span>
              </div>
            );
          }
          return (
            <div
              key={m.id}
              className={`flex gap-2.5 ${m.isMe ? "flex-row-reverse" : ""}`}
              onMouseEnter={() => setHovered(m.id)}
              onMouseLeave={() => setHovered(null)}
            >
              {!m.isMe && (
                <Avatar className="w-7 h-7 flex-shrink-0 mt-1">
                  <AvatarFallback className={`text-[10px] font-bold ${m.isDM ? "bg-purple-100 text-purple-700" : "bg-violet-100 text-violet-700"}`}>
                    {m.initial}
                  </AvatarFallback>
                </Avatar>
              )}
              <div className={`flex flex-col max-w-[78%] ${m.isMe ? "items-end" : "items-start"}`}>
                {!m.isMe && (
                  <div className="flex items-baseline gap-2 mb-0.5">
                    <span className="text-xs font-semibold text-foreground">{m.sender}</span>
                    <span className="text-[10px] text-neutral-400">{m.time}</span>
                    {m.isDM && <span className="text-[10px] text-purple-600 font-semibold bg-purple-100 dark:bg-purple-900/30 px-1.5 rounded-full">DM</span>}
                  </div>
                )}
                <div className={`relative px-3 py-2 rounded-2xl text-sm leading-relaxed ${
                  m.isMe
                    ? "bg-violet-600 text-white rounded-br-sm"
                    : m.isDM
                      ? "bg-purple-50 dark:bg-purple-900/20 text-purple-900 dark:text-purple-100 border border-purple-100 dark:border-purple-800/30 rounded-bl-sm"
                      : "bg-secondary text-foreground rounded-bl-sm"
                }`}>
                  {m.content}
                  {m.file && (
                    <div className="mt-2 bg-card rounded-lg p-2 border border-border flex items-center gap-2 w-44">
                      <div className="w-7 h-7 rounded bg-red-100 dark:bg-red-900/30 flex items-center justify-center text-red-600 flex-shrink-0">
                        <Paperclip className="w-3 h-3" />
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="text-[11px] font-medium truncate text-foreground">{m.file.name}</div>
                        <div className="text-[10px] text-muted-foreground">{m.file.size}</div>
                      </div>                        {/* "Save…" button per inventory §5 */}
                        <button className="text-[11px] font-semibold text-violet-600 dark:text-violet-400 hover:underline flex-shrink-0">Save…</button>                      <button className="text-neutral-400 hover:text-neutral-600 flex-shrink-0">
                        <Download className="w-3.5 h-3.5" />
                      </button>
                    </div>
                  )}

                  {/* Hover emoji reaction strip — Zoom pattern */}
                  {hovered === m.id && (
                    <div className={`absolute -top-9 ${m.isMe ? "right-0" : "left-0"} flex items-center bg-card border border-border rounded-full px-1.5 py-1 shadow-lg z-10 gap-0.5`}>
                      {REACTIONS.map((r) => (
                        <button key={r} className="text-sm leading-none hover:scale-125 transition-transform px-0.5">{r}</button>
                      ))}
                      <span className="w-px h-4 bg-neutral-200 dark:bg-neutral-600 mx-0.5" />
                      <button className="text-muted-foreground hover:text-foreground">
                        <MoreHorizontal className="w-3.5 h-3.5" />
                      </button>
                    </div>
                  )}
                </div>
                {m.isMe && <span className="text-[10px] text-neutral-400 mt-1">{m.time}</span>}
              </div>
            </div>
          );
        })}
      </div>

      {/* Compose — 📎 | input | 😊 | ➤ with recipient selector */}
      <div className="flex-shrink-0 border-t border-border bg-muted">
        {/* To: recipient dropdown — "Everyone" + individual names per inventory §5 */}
        <div className="px-3 pt-2 pb-1.5">
          <div className="relative inline-block">
            <select
              value={recipient}
              onChange={e => setRecipient(e.target.value)}
              className="appearance-none text-xs font-semibold text-foreground bg-transparent cursor-pointer pr-4 focus:outline-none"
            >
              {RECIPIENTS.map(r => <option key={r}>{r}</option>)}
            </select>
            <span className="text-[10px] text-muted-foreground absolute left-0 -top-2.5">To:</span>
            <ChevronDown className="w-3 h-3 absolute right-0 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none" />
          </div>
        </div>
        <div className="px-3 pb-3 flex items-center gap-2">
          <button className="w-8 h-8 flex-shrink-0 rounded-full flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors">
            <Paperclip className="w-4 h-4" />
          </button>
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            /* Placeholder changes to "DM to [name]…" when a person is selected */
            placeholder={recipient === "Everyone" ? "Type a message…" : `DM to ${recipient}…`}
            className="flex-1 bg-card border border-border rounded-full px-4 py-2 text-sm outline-none focus:border-violet-400 dark:focus:border-violet-500 transition-colors placeholder:text-neutral-400 dark:text-neutral-100"
          />
          <button className="w-8 h-8 flex-shrink-0 rounded-full flex items-center justify-center text-neutral-500 hover:bg-secondary transition-colors">
            <Smile className="w-4 h-4" />
          </button>
          <button
            disabled={!input.trim()}
            className={`w-8 h-8 flex-shrink-0 rounded-full flex items-center justify-center transition-colors ${
              input.trim() ? "bg-violet-600 hover:bg-violet-700 text-white" : "text-neutral-300 dark:text-neutral-600"
            }`}
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  );
}
