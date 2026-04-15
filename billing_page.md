# Billing Page — Web-Based Pricing Panel Implementation Plan

> Created: 12 April 2026
> Status: Planning
> Scope: Server-rendered pricing page, checkout redirect bridge, client integration
> Security model: Short-lived single-purpose JWT (1 min), CSRF-proof, no session cookies

---

## 1. Problem Statement

The app currently has a hardcoded "Upgrade to Pro" button that sends the user directly to an LS checkout page for variant `1516868`. There is no way for the user to:

- Compare plans side-by-side (Free vs Pro vs Pro+)
- See what each tier provides
- Choose between Pro and Pro+ before entering checkout
- See their current plan highlighted

**Goal:** A server-rendered HTML pricing page that users can view from the app, compare all plans, and click "Buy" on the plan they want — then seamlessly enter the LS checkout flow and return to the app.

---

## 2. User Flow (End-to-End)

```
┌── macOS App ──────────────────────────────────────┐
│                                                    │
│  User clicks "View Plans" button                   │
│       │                                            │
│       ▼                                            │
│  App calls GET /billing/plans-token                │
│  (Bearer auth — existing access token)             │
│       │                                            │
│       ▼                                            │
│  Server returns { url: "/billing/plans?t=<jwt>" }  │
│       │                                            │
│       ▼                                            │
│  App opens URL in default browser via NSWorkspace   │
│                                                    │
└────────────────────────────────────────────────────┘

┌── Browser ────────────────────────────────────────┐
│                                                    │
│  GET /billing/plans?t=<jwt>                        │
│       │                                            │
│       ▼                                            │
│  Server validates JWT (1-min expiry, purpose=plans)│
│  Server reads user's current tier from DB          │
│  Server renders HTML pricing page with:            │
│    - 3 plan cards (Free / Pro / Pro+)              │
│    - Current plan highlighted                      │
│    - "Buy" buttons only on upgrade paths           │
│       │                                            │
│       ▼                                            │
│  User clicks "Buy Pro+" button                     │
│       │                                            │
│       ▼                                            │
│  POST /billing/checkout-redirect                   │
│  (variantId + page token in hidden form)           │
│       │                                            │
│       ▼                                            │
│  Server validates token, creates LS checkout,      │
│  302 redirects browser to LS hosted checkout       │
│       │                                            │
│       ▼                                            │
│  User completes payment on LS                      │
│       │                                            │
│       ▼                                            │
│  LS redirects to /billing/success                  │
│  (existing bridge page)                            │
│       │                                            │
│       ▼                                            │
│  Bridge page fires inter://billing/success         │
│  deep link → app foregrounds                       │
│                                                    │
└────────────────────────────────────────────────────┘

┌── macOS App ──────────────────────────────────────┐
│                                                    │
│  Deep link handler fires                           │
│  → refreshAndWaitForTierChange (existing)          │
│  → Token refresh → new tier in JWT                 │
│  → UI updates: "Upgraded to Pro+!"                 │
│  → Button swaps to "Manage Subscription"           │
│                                                    │
└────────────────────────────────────────────────────┘
```

---

## 3. Security Design (Primary Focus)

### 3.1 Page Token — Short-Lived, Single-Purpose JWT

The pricing page is loaded in a browser where the user has no existing session with our server. We need a way to identify the user without creating a full browser session or exposing the access token in a URL.

**Solution: Purpose-scoped page token.**

```javascript
// Issued by: GET /billing/plans-token (requires Bearer auth)
// Used by:   GET /billing/plans?t=<token>
//            POST /billing/checkout-redirect (form hidden field)

const pageToken = jwt.sign(
  {
    sub:     userId,        // identifies the user
    purpose: 'billing',     // restricts usage — never accepted by other endpoints
    tier:    currentTier,   // embedded so plans page can render without additional DB call
  },
  JWT_SECRET,               // reuses existing secret — no new secret to manage
  {
    algorithm: 'HS256',
    expiresIn: '2m',        // 2-minute window — enough time for the page to load
    issuer:    'inter-token-server',
    audience:  'inter-billing-page',   // different audience — auth middleware rejects this
  }
);
```

**Security properties:**

| Property | How it's enforced |
|---|---|
| **Cannot be used as an API token** | `audience: 'inter-billing-page'` — the global `authenticateToken` middleware expects `audience: 'inter-macos-client'` and will reject it |
| **Cannot be replayed after 2 min** | `expiresIn: '2m'` — even if the URL is bookmarked/shared, it expires |
| **Cannot be used to modify data** | `purpose: 'billing'` — checkout-redirect endpoint validates this claim before proceeding |
| **Cannot be forged** | Signed with HS256 + JWT_SECRET (≥32 bytes, validated at startup) |
| **Cannot be intercepted (production)** | HSTS header enforces TLS; page sets `Cache-Control: no-store` |
| **Leaks no PII in URL** | Token is opaque; URL has no email, userId, or name visible |

### 3.2 Why Not Cookies / Sessions?

- **No cookie infrastructure exists** — adding `express-session` + Redis sessions is a new attack surface (CSRF, session fixation, cookie theft) for a single page
- **No `SameSite` / `Secure` / `HttpOnly` cookie policy to maintain** — the app only uses Bearer tokens
- **Stateless** — no server-side session store needed; JWT is self-contained

### 3.3 Checkout Creation — Server-Side Only

The "Buy" button on the pricing page does NOT call the LS API from the browser. It submits a form to our server:

```
POST /billing/checkout-redirect
Content-Type: application/x-www-form-urlencoded

variantId=1516868&token=<page-token>
```

The server:
1. Validates the page token (signature, expiry, purpose, audience)
2. Validates variantId against `ALLOWED_VARIANT_IDS`
3. Creates the LS checkout server-side (using the server's `LEMONSQUEEZY_API_KEY`)
4. 302 redirects the browser to the LS checkout URL

**Why a form POST and not a link with the token in the URL?**
- LS API key never touches the browser
- variantId validation happens server-side before any LS API call
- The Referer header from the redirect won't contain the token (POST body vs query string)
- Lemon Squeezy checkout URL is signed and short-lived (30 min) — safe to redirect to

### 3.4 CSRF Protection

The pricing page uses a **form POST** to `/billing/checkout-redirect`. CSRF protection:

1. **Token-bound** — the page token in the hidden form field is tied to the authenticated user and expires in 2 minutes. An attacker would need to obtain a valid, unexpired token to forge the form.
2. **No cookies** — there are no session cookies to ride. A cross-origin form submission would not carry any authentication — the token must be present in the form body.
3. **Origin validation (belt-and-suspenders)** — the checkout-redirect endpoint also checks the `Origin` or `Referer` header against allowed origins.

### 3.5 Security Headers on Billing Pages

The billing HTML pages add these headers **on top of** the global security middleware:

```javascript
res.setHeader('Content-Security-Policy',
  "default-src 'none'; " +
  "style-src 'unsafe-inline'; " +     // inline CSS only — no external stylesheets
  "script-src 'none'; " +             // NO JavaScript at all on the pricing page
  "form-action 'self'; " +            // forms can only submit to our own server
  "frame-ancestors 'none'"            // cannot be iframed
);
res.setHeader('X-Frame-Options', 'DENY');         // redundant with CSP but defense-in-depth
res.setHeader('X-Content-Type-Options', 'nosniff');
res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
res.setHeader('Pragma', 'no-cache');
```

**Key decisions:**
- `script-src 'none'` — the pricing page needs ZERO JavaScript. Plan cards are static HTML. "Buy" buttons are plain `<form>` submissions. This eliminates XSS as an attack vector entirely.
- `form-action 'self'` — prevents a hypothetical XSS elsewhere from adding a form that exfiltrates the token to an attacker's server
- `frame-ancestors 'none'` — prevents clickjacking

### 3.6 Input Validation Matrix

| Endpoint | Input | Validation |
|---|---|---|
| `GET /billing/plans-token` | Bearer token in header | `requireAuth` middleware (existing) |
| `GET /billing/plans?t=<jwt>` | `t` query param | JWT verify: algorithm=HS256, issuer, audience=`inter-billing-page`, purpose=`billing`, expiry |
| `POST /billing/checkout-redirect` | `token` (form field) | Same JWT validation as above |
| `POST /billing/checkout-redirect` | `variantId` (form field) | String, present, member of `ALLOWED_VARIANT_IDS` |

### 3.7 Threat Model

| Threat | Mitigation |
|---|---|
| Token in URL leaked via Referer | 2-min expiry window; checkout-redirect is POST not GET; `Referrer-Policy: no-referrer` on all responses |
| Token in browser history | Expires in 2 min; URL is not reusable; purpose-scoped |
| Man-in-the-middle | TLS enforced via HSTS (prod); ngrok uses HTTPS (dev) |
| XSS on pricing page | `script-src 'none'` in CSP — no JS at all |
| CSRF checkout creation | Token in form body (not cookie); no session to hijack |
| Clickjacking | `frame-ancestors 'none'` + `X-Frame-Options: DENY` |
| Price/plan tampering | variantId validated server-side; LS dashboard defines actual prices |
| Enumeration of plans | Public information — intentional; no PII on the page |
| Brute-force token guessing | 256-bit HS256 signature; rate limiting on server |
| Token replay after expiry | JWT `exp` claim; `jwt.verify()` rejects expired tokens |
| Stale tier display | Page token embeds tier at generation time; 2-min window minimizes staleness |

---

## 4. Server Implementation

### 4.1 Plan Configuration (in index.js or separate config)

Plans are defined server-side. This is the single source of truth for what the pricing page renders.

```javascript
const BILLING_PLANS = [
  {
    tier: 'free',
    name: 'Free',
    price: 0,
    currency: 'INR',
    interval: 'month',
    variantId: null,            // no checkout for free
    badge: null,
    features: [
      '1-on-1 video calls',
      '30-minute call limit',
      'Standard quality',
      'Basic screen sharing',
    ],
    limitations: [
      'No group calls',
      'No recording',
      'No interview mode',
    ],
  },
  {
    tier: 'pro',
    name: 'Pro',
    price: 1000,
    currency: 'INR',
    interval: 'month',
    variantId: '1516868',
    badge: 'Popular',           // highlighted card
    features: [
      'Everything in Free',
      'Group calls (up to 10)',
      'No time limit',
      'HD video quality',
      'Screen sharing with audio',
      'Cloud recording',
      'Chat & Q/A in meetings',
    ],
    limitations: [
      'No interview mode',
      'No candidate lockdown',
    ],
  },
  {
    tier: 'pro+',
    name: 'Pro+',
    price: 2000,
    currency: 'INR',
    interval: 'month',
    variantId: '1516865',
    badge: 'For Hiring Teams',
    features: [
      'Everything in Pro',
      'Interview mode',
      'Candidate lockdown (kiosk)',
      'Secure window enforcement',
      'Speaker queue management',
      'Live polling',
      'Lobby & waiting room',
      'Moderation controls',
    ],
    limitations: [],
  },
];
```

**To add/modify plans:** Edit this array and restart the server. No app rebuild needed.

### 4.2 New Endpoints

#### `GET /billing/plans-token` (protected)

Returns a short-lived URL that the macOS app opens in the browser.

```javascript
app.get('/billing/plans-token', auth.requireAuth, async (req, res) => {
  // Fresh tier read from DB — don't trust JWT tier (could be stale)
  const result = await db.query(
    'SELECT tier FROM users WHERE id = $1',
    [req.user.userId]
  );
  const user = result.rows[0];
  if (!user) {
    return res.status(404).json({ code: 'USER_NOT_FOUND', error: 'User not found' });
  }

  const pageToken = jwt.sign(
    { sub: req.user.userId, purpose: 'billing', tier: user.tier || 'free' },
    JWT_SECRET,
    { algorithm: 'HS256', expiresIn: '2m', issuer: 'inter-token-server', audience: 'inter-billing-page' }
  );

  const baseURL = process.env.BILLING_PAGE_BASE_URL || `http://localhost:${PORT}`;
  res.json({ url: `${baseURL}/billing/plans?t=${encodeURIComponent(pageToken)}` });
});
```

#### `GET /billing/plans?t=<token>` (token-auth via query param)

Validates the page token, renders the HTML pricing page.

```javascript
app.get('/billing/plans', (req, res) => {
  const token = req.query.t;
  if (!token) {
    return res.status(401).send(renderErrorPage('Missing authentication token.'));
  }

  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET, {
      algorithms: ['HS256'],
      issuer: 'inter-token-server',
      audience: 'inter-billing-page',
    });
  } catch (err) {
    const msg = err.name === 'TokenExpiredError'
      ? 'This link has expired. Go back to Inter and click "View Plans" again.'
      : 'Invalid authentication token.';
    return res.status(401).send(renderErrorPage(msg));
  }

  if (payload.purpose !== 'billing') {
    return res.status(403).send(renderErrorPage('Invalid token purpose.'));
  }

  const currentTier = payload.tier || 'free';
  const html = renderPricingPage(BILLING_PLANS, currentTier, token);

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Content-Security-Policy',
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; form-action 'self'; frame-ancestors 'none'");
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.send(html);
});
```

#### `POST /billing/checkout-redirect` (token-auth via form body)

Validates token + variantId, creates LS checkout, 302 redirects.

```javascript
app.post('/billing/checkout-redirect', express.urlencoded({ extended: false }), async (req, res) => {
  const { token, variantId } = req.body || {};

  // 1. Validate token
  if (!token) {
    return res.status(401).send(renderErrorPage('Missing authentication token.'));
  }

  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET, {
      algorithms: ['HS256'],
      issuer: 'inter-token-server',
      audience: 'inter-billing-page',
    });
  } catch (err) {
    const msg = err.name === 'TokenExpiredError'
      ? 'This link has expired. Go back to Inter and click "View Plans" again.'
      : 'Invalid authentication token.';
    return res.status(401).send(renderErrorPage(msg));
  }

  if (payload.purpose !== 'billing') {
    return res.status(403).send(renderErrorPage('Invalid token purpose.'));
  }

  // 2. Validate variantId
  if (!variantId || typeof variantId !== 'string') {
    return res.status(400).send(renderErrorPage('Invalid plan selection.'));
  }
  const ALLOWED_VARIANT_IDS = new Set(Object.keys(VARIANT_ID_TO_TIER));
  if (!ALLOWED_VARIANT_IDS.has(variantId)) {
    return res.status(400).send(renderErrorPage('Invalid plan selection.'));
  }

  // 3. Lookup user
  const userResult = await db.query(
    'SELECT email, display_name FROM users WHERE id = $1',
    [payload.sub]
  );
  const user = userResult.rows[0];
  if (!user) {
    return res.status(404).send(renderErrorPage('Account not found.'));
  }

  // 4. Create LS checkout
  let checkout;
  try {
    checkout = await createCheckout(
      process.env.LEMONSQUEEZY_STORE_ID,
      variantId,
      {
        checkoutData: {
          email: user.email,
          name: user.display_name || undefined,
          custom: { user_id: payload.sub },
        },
        productOptions: {
          redirectUrl: process.env.APP_RETURN_URL || 'inter://billing/success',
        },
        expiresAt: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
      }
    );
  } catch (err) {
    console.error(`[billing] checkout-redirect: createCheckout threw for user=${payload.sub}:`, err.message);
    return res.status(502).send(renderErrorPage('Failed to create checkout. Please try again.'));
  }

  const url = checkout?.data?.data?.attributes?.url;
  if (!url) {
    return res.status(502).send(renderErrorPage('Failed to create checkout. Please try again.'));
  }

  // 5. Redirect to LS checkout
  res.redirect(302, url);
});
```

### 4.3 HTML Rendering Functions

Two rendering functions needed:

- `renderPricingPage(plans, currentTier, token)` — returns the full pricing HTML
- `renderErrorPage(message)` — returns a simple error page with a message

Both are pure functions that return HTML strings (same pattern as the existing `/billing/success` page). No template engine dependency needed — template literals are sufficient.

### 4.4 Pricing Page HTML Structure

```
┌──────────────────────────────────────────────────────────┐
│                     Choose Your Plan                      │
│           You're currently on the Free plan.              │
│                                                          │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Free   │  │  ★ Popular   │  │ For Hiring   │       │
│  │          │  │              │  │    Teams     │       │
│  │   ₹0    │  │   ₹1,000    │  │   ₹2,000    │       │
│  │  /month  │  │   /month    │  │   /month    │       │
│  │          │  │              │  │              │       │
│  │ ✓ feat1  │  │ ✓ feat1     │  │ ✓ feat1     │       │
│  │ ✓ feat2  │  │ ✓ feat2     │  │ ✓ feat2     │       │
│  │ ✗ feat3  │  │ ✓ feat3     │  │ ✓ feat3     │       │
│  │          │  │              │  │              │       │
│  │[Cur Plan]│  │  [ Buy ]    │  │  [ Buy ]    │       │
│  └──────────┘  └──────────────┘  └──────────────┘       │
│                                                          │
│        Payments processed securely by Lemon Squeezy.     │
│          Questions? Contact support@inter.app            │
└──────────────────────────────────────────────────────────┘
```

**Card rendering rules (based on currentTier):**

| User's current tier | Free card | Pro card | Pro+ card |
|---|---|---|---|
| `free` | "Current Plan" (disabled) | "Upgrade to Pro" (active) | "Upgrade to Pro+" (active) |
| `pro` | No button | "Current Plan" (disabled) | "Upgrade to Pro+" (active) |
| `pro+` | No button | No button | "Current Plan" (disabled) |

**No downgrade buttons.** Downgrade is handled exclusively through LS portal ("Manage Subscription").

---

## 5. Client Changes

### 5.1 InterTokenService.swift — New Method

```swift
/// Fetch a signed billing page URL from the server.
/// The URL contains a short-lived token that authenticates the user on the pricing page.
@objc public func requestBillingPageURL(
    completion: @escaping (_ url: String?) -> Void
)
```

Calls `GET /billing/plans-token` with Bearer auth, returns the `url` field.

### 5.2 AppDelegate.m — Button Changes

**Replace:**
- "Upgrade to Pro" button → **"View Plans"** button
- `handleUpgradeToPro` → **`handleViewPlans`** (calls `requestBillingPageURL`, opens result in browser)

**Keep unchanged:**
- "Manage Subscription" button (for paid users)
- `handleManageSubscription` method
- `handleBillingSuccessDeepLink` (deep link handler)
- `billingStatusLabel` (status feedback)

### 5.3 Updated Button Logic

```
if (currentTier == "free") {
    show "View Plans" button → handleViewPlans
} else {
    show "View Plans" button → handleViewPlans     // paid users can still view plans
    show "Manage Subscription" button → handleManageSubscription
}
```

Even paid users see "View Plans" — they might want to upgrade from Pro to Pro+ or just review their current plan.

---

## 6. Files to Create/Modify

| File | Action | Description |
|---|---|---|
| `token-server/index.js` | Modify | Add 3 new endpoints: `GET /billing/plans-token`, `GET /billing/plans`, `POST /billing/checkout-redirect` |
| `token-server/billing-page.js` | Create | `renderPricingPage()` and `renderErrorPage()` functions + `BILLING_PLANS` config |
| `inter/Networking/InterTokenService.swift` | Modify | Add `requestBillingPageURL(completion:)` |
| `inter/App/AppDelegate.m` | Modify | Replace "Upgrade to Pro" with "View Plans", update handler |

**No new dependencies.** Uses existing `jsonwebtoken`, `express`, `@lemonsqueezy/lemonsqueezy.js`.

---

## 7. What Can Be Changed Without App Rebuild

| Change | Where to edit | App rebuild? |
|---|---|---|
| Plan prices | `BILLING_PLANS` in `billing-page.js` + LS dashboard | No |
| Feature descriptions | `BILLING_PLANS.features[]` array | No |
| Add a new tier | Add to `BILLING_PLANS` + `VARIANT_ID_TO_TIER` + LS dashboard | No |
| Remove a tier | Remove from `BILLING_PLANS` | No |
| Change recommended plan badge | Move `badge: 'Popular'` | No |
| Add limitations list | Add `limitations` array to plan config | No |
| Change card colors/fonts | Edit CSS in `renderPricingPage()` | No |
| Change layout (e.g. tabs instead of cards) | Edit HTML in `renderPricingPage()` | No |
| Add animations | Edit CSS in `renderPricingPage()` | No |
| Add testimonials section | Edit `renderPricingPage()` HTML | No |
| Change "View Plans" button text | Edit `AppDelegate.m` | **Yes** |

---

## 8. Testing Plan

| Test | Type | What it verifies |
|---|---|---|
| `GET /billing/plans-token` without auth → 401 | Integration | Endpoint is protected |
| `GET /billing/plans-token` with auth → returns URL with token | Integration | Token generation works |
| `GET /billing/plans` with expired token → error page | Integration | Expiry enforcement |
| `GET /billing/plans` with valid token → renders 3 cards | Integration | HTML rendering |
| `GET /billing/plans` with access token (wrong audience) → rejected | Security | Audience isolation |
| `POST /billing/checkout-redirect` with tampered variantId → 400 | Security | Input validation |
| `POST /billing/checkout-redirect` with expired token → error page | Security | Token expiry on form submit |
| `POST /billing/checkout-redirect` with valid inputs → 302 to LS | Integration | Full checkout flow |
| Page token cannot be used in `Authorization: Bearer` header | Security | Purpose isolation |
| `Content-Security-Policy` header present on pricing page | Security | CSP enforcement |
| `script-src 'none'` blocks injected script tags | Security | XSS prevention |
| Pricing page has no JavaScript | Audit | Manual review |
| Free user sees "Current Plan" on Free, "Buy" on Pro and Pro+ | UI | Correct CTA rendering |
| Pro user sees "Current Plan" on Pro, "Buy" on Pro+ only | UI | No downgrade path |
| Pro+ user sees "Current Plan" on Pro+, no "Buy" buttons | UI | No downgrade path |

---

## 9. Security Checklist (Pre-Deployment)

- [ ] Page token uses different `audience` than access tokens
- [ ] Page token has `purpose: 'billing'` claim validated on every use
- [ ] Page token expiry ≤ 2 minutes
- [ ] `GET /billing/plans` returns `Content-Security-Policy` with `script-src 'none'`
- [ ] `POST /billing/checkout-redirect` validates variantId against `ALLOWED_VARIANT_IDS`
- [ ] `POST /billing/checkout-redirect` validates token before any LS API call
- [ ] No JavaScript on the pricing page (pure HTML + CSS)
- [ ] No cookies set by any billing endpoint
- [ ] `Cache-Control: no-store` on all billing pages
- [ ] LS API key never exposed to the browser
- [ ] User email/name never rendered in the HTML (only tier badge)
- [ ] Pricing page cannot be iframed (`frame-ancestors 'none'`)
- [ ] Error pages do not leak internal details (no stack traces, no user IDs)
- [ ] `Referrer-Policy: no-referrer` prevents token leakage via Referer header

---

## 10. Implementation Order

1. **Create `billing-page.js`** — `BILLING_PLANS` config + `renderPricingPage()` + `renderErrorPage()`
2. **Add `GET /billing/plans-token`** endpoint to `index.js`
3. **Add `GET /billing/plans`** endpoint to `index.js`
4. **Add `POST /billing/checkout-redirect`** endpoint to `index.js`
5. **Add `requestBillingPageURL`** method to `InterTokenService.swift`
6. **Update `AppDelegate.m`** — replace "Upgrade to Pro" → "View Plans", wire new handler
7. **Remove old `POST /billing/checkout`** endpoint (superseded by checkout-redirect)
8. **Remove old `requestCheckoutURL`** method from InterTokenService.swift
9. **Test full flow** — app → browser → pricing → checkout → deep link → app
10. **Security audit** — run through §9 checklist
