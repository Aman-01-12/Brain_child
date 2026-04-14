'use strict';

// ---------------------------------------------------------------------------
// billing-page.js — Pricing page rendering + plan configuration
//
// BILLING_PLANS is the single source of truth for what the pricing page
// renders. Modify this array and restart the server to change plans, prices,
// features, or badges with no app rebuild required.
//
// renderPricingPage(plans, currentTier, token) → HTML string
// renderErrorPage(message)                     → HTML string
// ---------------------------------------------------------------------------

const BILLING_PLANS = [
  {
    tier: 'free',
    name: 'Free',
    price: 0,
    currency: 'INR',
    interval: 'month',
    variantId: null,          // no checkout for the free tier
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
    badge: 'Popular',
    features: [
      'Everything in Free',
      'Group calls (up to 10)',
      'No time limit',
      'HD video quality',
      'Screen sharing with audio',
      'Cloud recording',
      'Chat & Q&A in meetings',
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

// ---------------------------------------------------------------------------
// Tier ordering — used to determine whether a plan is an upgrade path
// ---------------------------------------------------------------------------
const TIER_ORDER = { free: 0, pro: 1, 'pro+': 2 };

// ---------------------------------------------------------------------------
// renderPricingPage
// ---------------------------------------------------------------------------
function renderPricingPage(plans, currentTier, token) {
  const isAuthenticated = !!token;
  const tierOrder = TIER_ORDER[currentTier] ?? 0;

  const formatPrice = (price, currency) => {
    const formatted = new Intl.NumberFormat('en-IN', {
      style: 'currency',
      currency,
      maximumFractionDigits: 0,
    }).format(price);
    return `<span class="price-amount">${formatted}</span>`;
  };

  const renderFeatures = (features, limitations) => {
    const pos = features.map(f => `<li class="feat feat-yes">✓ ${escHtml(f)}</li>`).join('\n');
    const neg = limitations.map(l => `<li class="feat feat-no">✗ ${escHtml(l)}</li>`).join('\n');
    return `<ul class="feat-list">${pos}${neg}</ul>`;
  };

  const renderButton = (plan) => {
    const planOrder = TIER_ORDER[plan.tier] ?? 0;

    // Free tier has no upgrade button (it has no variantId)
    if (!plan.variantId) {
      return ``;
    }

    // Unauthenticated visitor — show disabled prompt button
    if (!isAuthenticated) {
      const label = plan.tier === 'pro+' ? 'Get Pro+' : `Get ${escHtml(plan.name)}`;
      return `<button class="btn btn-signin" disabled>${label} — Sign in first</button>`;
    }

    // Current plan
    if (plan.tier === currentTier) {
      return `<button class="btn btn-current" disabled>Current Plan</button>`;
    }

    // Downgrade path — no button per design spec
    if (planOrder < tierOrder) {
      return ``;
    }

    // Upgrade path — hidden form POST (no JS required)
    const label = plan.tier === 'pro+' ? 'Upgrade to Pro+' : `Upgrade to ${escHtml(plan.name)}`;
    return `
      <form method="POST" action="/billing/checkout-redirect">
        <input type="hidden" name="token" value="${escAttr(token)}">
        <input type="hidden" name="variantId" value="${escAttr(plan.variantId)}">
        <button type="submit" class="btn btn-upgrade">${label}</button>
      </form>`;
  };

  const cards = plans.map(plan => {
    const isCurrentPlan = plan.tier === currentTier;
    const isBadged = !!plan.badge;
    const cardClass = [
      'plan-card',
      isCurrentPlan ? 'plan-current' : '',
      isBadged ? 'plan-featured' : '',
    ].filter(Boolean).join(' ');

    const badgeHtml = plan.badge
      ? `<div class="plan-badge">${escHtml(plan.badge)}</div>`
      : '';

    return `
    <div class="${cardClass}">
      ${badgeHtml}
      <div class="plan-name">${escHtml(plan.name)}</div>
      <div class="plan-price">
        ${formatPrice(plan.price, plan.currency)}
        ${plan.price > 0 ? `<span class="price-interval">/ ${escHtml(plan.interval)}</span>` : '<span class="price-interval">forever</span>'}
      </div>
      ${renderFeatures(plan.features, plan.limitations)}
      <div class="plan-action">
        ${renderButton(plan)}
      </div>
    </div>`;
  }).join('\n');

  const currentPlanName = plans.find(p => p.tier === currentTier)?.name ?? 'Free';
  const subtitleHtml = isAuthenticated
    ? `You are currently on the <strong>${escHtml(currentPlanName)}</strong> plan.`
    : `Sign in from the Inter app to purchase a plan.`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Choose Your Plan — Inter</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d0d0d;
      color: #e0e0e0;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 48px 24px 64px;
    }

    h1 {
      font-size: 28px;
      font-weight: 700;
      color: #fff;
      margin-bottom: 8px;
      text-align: center;
    }

    .subtitle {
      font-size: 14px;
      color: #888;
      margin-bottom: 48px;
      text-align: center;
    }

    .plans {
      display: flex;
      gap: 20px;
      flex-wrap: wrap;
      justify-content: center;
      width: 100%;
      max-width: 960px;
    }

    .plan-card {
      background: #1a1a1a;
      border: 1px solid #2a2a2a;
      border-radius: 16px;
      padding: 32px 28px;
      flex: 1;
      min-width: 240px;
      max-width: 300px;
      display: flex;
      flex-direction: column;
      gap: 16px;
      position: relative;
    }

    .plan-card.plan-featured {
      border-color: #7c3aed;
      box-shadow: 0 0 0 1px #7c3aed;
    }

    .plan-card.plan-current {
      border-color: #2d6a4f;
    }

    .plan-badge {
      position: absolute;
      top: -12px;
      left: 50%;
      transform: translateX(-50%);
      background: #7c3aed;
      color: #fff;
      font-size: 11px;
      font-weight: 700;
      padding: 3px 12px;
      border-radius: 999px;
      white-space: nowrap;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }

    .plan-name {
      font-size: 20px;
      font-weight: 700;
      color: #fff;
    }

    .plan-price {
      display: flex;
      align-items: baseline;
      gap: 6px;
    }

    .price-amount {
      font-size: 32px;
      font-weight: 800;
      color: #fff;
    }

    .price-interval {
      font-size: 13px;
      color: #666;
    }

    .feat-list {
      list-style: none;
      display: flex;
      flex-direction: column;
      gap: 8px;
      flex: 1;
    }

    .feat {
      font-size: 13px;
      line-height: 1.4;
    }

    .feat-yes { color: #c8e6c9; }
    .feat-no  { color: #555; }

    .plan-action { margin-top: 8px; }

    .btn {
      width: 100%;
      padding: 12px;
      border-radius: 10px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      border: none;
      transition: background 0.15s;
    }

    .btn-upgrade {
      background: #7c3aed;
      color: #fff;
    }
    .btn-upgrade:hover { background: #6d28d9; }

    .btn-current {
      background: #1f3d2e;
      color: #52b788;
      cursor: default;
    }

    .btn-signin {
      background: #2a2a2a;
      color: #888;
      cursor: default;
    }

    form { width: 100%; }

    .footer {
      margin-top: 48px;
      font-size: 12px;
      color: #555;
      text-align: center;
      line-height: 1.6;
    }

    .footer a { color: #7c3aed; text-decoration: none; }
    .footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h1>Choose Your Plan</h1>
  <p class="subtitle">${subtitleHtml}</p>

  <div class="plans">
    ${cards}
  </div>

  <div class="footer">
    Payments processed securely by <a href="https://www.lemonsqueezy.com" rel="noopener noreferrer">Lemon Squeezy</a>.<br>
    Questions? <a href="mailto:support@inter.app">support@inter.app</a>
  </div>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// renderErrorPage
// ---------------------------------------------------------------------------
function renderErrorPage(message) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Error — Inter</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d0d0d;
      color: #e0e0e0;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
    }
    .card {
      text-align: center;
      max-width: 420px;
      padding: 48px 32px;
      background: #1a1a1a;
      border-radius: 16px;
      border: 1px solid #333;
    }
    .icon { font-size: 40px; margin-bottom: 16px; }
    h1 { font-size: 20px; color: #fff; margin-bottom: 12px; }
    p  { font-size: 14px; color: #888; line-height: 1.6; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">⚠️</div>
    <h1>Something went wrong</h1>
    <p>${escHtml(message)}</p>
  </div>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// escHtml / escAttr — output-encoding helpers (no external dep required)
// ---------------------------------------------------------------------------
function escHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

function escAttr(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

module.exports = { BILLING_PLANS, renderPricingPage, renderErrorPage };
