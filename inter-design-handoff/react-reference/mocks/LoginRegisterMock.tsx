import React, { useState } from "react";
import { Label } from "../ui/label";
import { Input } from "../ui/input";
import { Button } from "../ui/button";
import { Eye, EyeOff, Loader2 } from "lucide-react";

const STRENGTH_META = [
  { label: "",            color: "bg-muted"       },
  { label: "Weak",        color: "bg-red-500"     },
  { label: "Fair",        color: "bg-amber-500"   },
  { label: "Strong",      color: "bg-emerald-500" },
  { label: "Very strong", color: "bg-emerald-600" },
];

/**
 * Password strength scoring per inventory §2:
 * Score 0 (empty): no bars, no label
 * Score 1 (< 8 chars): 1 bar red, "Weak"
 * Score 2 (any 2 character categories): 2 bars orange, "Fair"
 * Score 3 (≥10 chars, ≥3 categories): 3 bars green, "Strong"
 * Score 4 (≥12 chars, ≥3 categories): 4 bars green, "Very Strong"
 */
function getStrength(pw: string): number {
  if (!pw) return 0;
  if (pw.length < 8) return 1;
  const cats = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter(r => r.test(pw)).length;
  if (pw.length >= 12 && cats >= 3) return 4;
  if (pw.length >= 10 && cats >= 3) return 3;
  if (cats >= 2) return 2;
  return 1;
}

function GoogleIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24">
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
      <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z"/>
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
    </svg>
  );
}

function MicrosoftIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
      <path d="M11.4 24H0V12.6h11.4V24zM24 24H12.6V12.6H24V24zM11.4 11.4H0V0h11.4v11.4zM24 11.4H12.6V0H24v11.4z"/>
    </svg>
  );
}

export function LoginRegisterMock() {
  const [mode, setMode]         = useState<"signin" | "signup">("signin");
  const [showPw, setShowPw]     = useState(false);
  const [password, setPassword] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError]       = useState("");

  const strength = getStrength(password);
  const sm = STRENGTH_META[strength];

  const handleSubmit = () => {
    setError("");
    setIsLoading(true);
    setTimeout(() => {
      setIsLoading(false);
      // Simulate a validation error in demo
      if (mode === "signin") setError("Invalid email or password. Please try again.");
    }, 1200);
  };

  return (
    <div className="w-[420px] font-sans">
      <div className="rounded-2xl border border-border bg-card shadow-xl overflow-hidden">
        {/* Brand header */}
        <div className="px-8 pt-8 pb-6 text-center border-b border-border">
          <div className="w-12 h-12 rounded-2xl bg-neutral-950 dark:bg-white mx-auto flex items-center justify-center shadow mb-4">
            <span className="text-white dark:text-neutral-900 font-bold text-xl tracking-tighter">In</span>
          </div>
          <h1 className="text-xl font-semibold text-foreground">
            {mode === "signin" ? "Sign In to Inter" : "Create an Account"}
          </h1>
          <p className="text-sm text-neutral-500 mt-1">
            {mode === "signin" ? "Welcome back to your workspace." : "Get started — it only takes a minute."}
          </p>
        </div>

        <div className="px-8 py-6 space-y-4">
          {/* OAuth — exact inventory labels: "Continue with Google/Microsoft" */}
          <div className="grid grid-cols-2 gap-3">
            <button className="flex items-center justify-center gap-2 h-9 rounded-lg border border-border bg-card text-sm font-medium text-foreground hover:bg-muted transition-colors">
              <GoogleIcon /> Continue with Google
            </button>
            <button className="flex items-center justify-center gap-2 h-9 rounded-lg border border-border bg-card text-sm font-medium text-foreground hover:bg-muted transition-colors">
              <MicrosoftIcon /> Continue with Microsoft
            </button>
          </div>

          <div className="flex items-center gap-3">
            <div className="flex-1 h-px bg-muted" />
            <span className="text-xs text-neutral-400">or continue with email</span>
            <div className="flex-1 h-px bg-muted" />
          </div>

          {/* Error label (red text) — shown on validation/server errors */}
          {error && (
            <div className="text-sm text-red-500 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800/30 rounded-lg px-3 py-2">
              {error}
            </div>
          )}

          {/* Form */}
          <div className="space-y-3">
            {mode === "signup" && (
              <div className="space-y-1.5">
                <Label className="text-xs font-medium">Display name</Label>
                <Input placeholder="Your name" className="h-9 text-sm" />
              </div>
            )}
            <div className="space-y-1.5">
              <Label className="text-xs font-medium">Email address</Label>
              <Input type="email" placeholder="you@example.com" className="h-9 text-sm" />
            </div>
            <div className="space-y-1.5">
              <div className="flex items-center justify-between">
                <Label className="text-xs font-medium">Password</Label>
                {mode === "signin" && (
                  <button className="text-xs text-violet-600 dark:text-violet-400 hover:underline">Forgot password?</button>
                )}
              </div>
              <div className="relative">
                <Input
                  type={showPw ? "text" : "password"}
                  placeholder="Minimum 8 characters"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="h-9 text-sm pr-16"
                />
                {/* "Show" / "Hide" label button per inventory */}
                <button
                  onClick={() => setShowPw(!showPw)}
                  className="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-violet-600 dark:text-violet-400 font-medium hover:underline flex items-center gap-1"
                >
                  {showPw ? <><EyeOff className="w-3.5 h-3.5" /> Hide</> : <><Eye className="w-3.5 h-3.5" /> Show</>}
                </button>
              </div>

              {/* Password strength bars — only signup, only when typing */}
              {mode === "signup" && password.length > 0 && (
                <div className="pt-1 space-y-1.5">
                  <div className="flex gap-1">
                    {[1, 2, 3, 4].map((i) => (
                      <div key={i} className={`h-1 flex-1 rounded-full transition-all duration-300 ${i <= strength ? sm.color : "bg-muted"}`} />
                    ))}
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="text-[11px] text-muted-foreground">Password strength</span>
                    <span className={`text-[11px] font-semibold ${strength >= 3 ? "text-emerald-600" : strength === 2 ? "text-amber-600" : "text-red-500"}`}>
                      {sm.label}
                    </span>
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* Primary CTA — shows spinner during async request */}
          <Button
            onClick={handleSubmit}
            disabled={isLoading}
            className="w-full h-10 bg-neutral-950 hover:bg-neutral-800 text-white dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-100 font-medium text-sm"
          >
            {isLoading
              ? <><Loader2 className="w-4 h-4 animate-spin mr-2" /> Signing in…</>
              : mode === "signin" ? "Log In" : "Create Account"
            }
          </Button>

          {/* Toggle link — inventory exact: "Create Account" / "Back to Login" */}
          <p className="text-center text-xs text-neutral-500 pt-1">
            {mode === "signin" ? "No account yet?" : "Already have an account?"}{" "}
            <button
              onClick={() => { setMode(mode === "signin" ? "signup" : "signin"); setError(""); setPassword(""); }}
              className="text-violet-600 dark:text-violet-400 font-medium hover:underline"
            >
              {mode === "signin" ? "Create Account" : "Back to Login"}
            </button>
          </p>
        </div>
      </div>
    </div>
  );
}
