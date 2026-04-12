#!/usr/bin/env node
// ============================================================================
// test-billing.js — Lemon Squeezy webhook integration test
//
// Tests the full billing pipeline with proper payload shapes:
//   - Subscription events: data.type = "subscriptions"
//   - Invoice events:      data.type = "subscription-invoices"
//
// Prerequisites:
//   1. Server running: node index.js (in another terminal)
//   2. Database with migrations applied
//
// Usage:
//   node test-billing.js
// ============================================================================

const crypto = require('crypto');
const http = require('http');

const PORT = process.env.PORT || 3000;
const BASE = `http://localhost:${PORT}`;
const WEBHOOK_SECRET = process.env.LEMONSQUEEZY_WEBHOOK_SECRET;
if (!WEBHOOK_SECRET) {
  console.error('Error: LEMONSQUEEZY_WEBHOOK_SECRET environment variable is required');
  process.exit(1);
}

// Test user credentials — created fresh each run
const TEST_EMAIL = `billing-test-${Date.now()}@example.com`;
const TEST_PASSWORD = 'TestPass123!';
const TEST_DISPLAY_NAME = 'Billing Tester';

// Variant IDs from billing.js
const VARIANT_PRO = '1516868';
const VARIANT_PRO_PLUS = '1516865';

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function request(method, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE);
    const payload = body ? (typeof body === 'string' ? body : JSON.stringify(body)) : null;

    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method,
      headers: {
        ...(payload && typeof body !== 'string' ? { 'Content-Type': 'application/json' } : {}),
        ...headers,
      },
    };

    const req = http.request(opts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let json;
        try { json = JSON.parse(raw); } catch { json = null; }
        resolve({ status: res.statusCode, body: json, raw });
      });
    });

    req.on('error', reject);
    if (payload) {
      if (typeof body === 'string') {
        req.setHeader('Content-Type', 'application/json');
      }
      req.write(payload);
    }
    req.end();
  });
}

function signPayload(jsonString) {
  return crypto.createHmac('sha256', WEBHOOK_SECRET).update(jsonString).digest('hex');
}

function sendWebhook(payload) {
  const raw = JSON.stringify(payload);
  const signature = signPayload(raw);
  return request('POST', '/webhooks/lemonsqueezy', raw, {
    'Content-Type': 'application/json',
    'X-Signature': signature,
  });
}

// ---------------------------------------------------------------------------
// Payload factories — exact replicas of real Lemon Squeezy webhook JSON
//
// These match the documented LS API object structures 1:1:
//   Subscription object: https://docs.lemonsqueezy.com/api/subscriptions
//   Invoice object:      https://docs.lemonsqueezy.com/api/subscription-invoices
//   Order object:        https://docs.lemonsqueezy.com/api/orders
//
// Each webhook payload has: { meta, data: { type, id, attributes, relationships, links } }
// ---------------------------------------------------------------------------

// LS uses microsecond-precision ISO 8601 timestamps (e.g. "2021-08-11T13:47:27.000000Z")
function lsTimestamp(offsetMs) {
  const d = typeof offsetMs === 'number' ? new Date(Date.now() + offsetMs) : new Date();
  return d.toISOString().replace(/\.(\d{3})Z$/, '.$1000Z');
}

// LS status_formatted: capitalize first char, replace _ with space
// e.g. "past_due" → "Past due", "on_trial" → "On trial"
function statusFormatted(s) {
  if (!s) return '';
  return s.charAt(0).toUpperCase() + s.slice(1).replace(/_/g, ' ');
}

// ---------------------------------------------------------------------------
// Subscription event payload (data.type = "subscriptions")
// Exactly matches: https://docs.lemonsqueezy.com/api/subscriptions/the-subscription-object
// ---------------------------------------------------------------------------
function buildSubscriptionPayload(eventName, userId, overrides = {}) {
  const now = lsTimestamp(0);
  const renews = lsTimestamp(30 * 24 * 60 * 60 * 1000);
  const subId = String(overrides.subscriptionId || '999001');
  const variantId = overrides.variantId || Number(VARIANT_PRO);
  const customerId = overrides.customerId || 800001;
  const productId = overrides.productId || 400001;
  const status = overrides.status || 'active';

  return {
    meta: {
      event_name: eventName,
      custom_data: { user_id: String(userId) },
    },
    data: {
      type: 'subscriptions',
      id: subId,
      attributes: {
        store_id: 342696,
        customer_id: customerId,
        order_id: 123456,
        order_item_id: 234567,
        product_id: productId,
        variant_id: variantId,
        product_name: 'Inter Pro',
        variant_name: variantId === Number(VARIANT_PRO_PLUS) ? 'Pro Plus Monthly' : 'Pro Monthly',
        user_name: TEST_DISPLAY_NAME,
        user_email: TEST_EMAIL,
        status: status,
        status_formatted: statusFormatted(status),
        card_brand: 'visa',
        card_last_four: '4242',
        payment_processor: 'stripe',
        pause: overrides.pause || null,
        cancelled: overrides.cancelled || false,
        trial_ends_at: overrides.trialEndsAt || null,
        billing_anchor: 12,
        first_subscription_item: {
          id: 345678,
          subscription_id: Number(subId) || 999001,
          price_id: 456789,
          quantity: 1,
          created_at: now,
          updated_at: overrides.updatedAt || now,
        },
        urls: {
          update_payment_method: `https://test-store.lemonsqueezy.com/subscription/${subId}/payment-details?expires=1666869343&signature=9985e3bf9007840aeb3951412be475abc17439c449c1af3e56e08e45e1345413`,
          customer_portal: `https://test-store.lemonsqueezy.com/billing?expires=1666869343&signature=82ae290ceac8edd4190c82825dd73a8743346d894a8ddbc4898b97eb96d105a5`,
          customer_portal_update_subscription: `https://test-store.lemonsqueezy.com/billing/${subId}/update?expires=1666869343&signature=e4fabc7ee703664d644bba9e79a9cd3dd00622308b335f3c166787f0b18999f2`,
        },
        renews_at: overrides.renewsAt || renews,
        ends_at: overrides.endsAt || null,
        created_at: overrides.createdAt || now,
        updated_at: overrides.updatedAt || now,
        test_mode: true,
        ...overrides.attributes,
      },
      relationships: {
        store: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/store`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/store`,
          },
        },
        customer: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/customer`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/customer`,
          },
        },
        order: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/order`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/order`,
          },
        },
        'order-item': {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/order-item`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/order-item`,
          },
        },
        product: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/product`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/product`,
          },
        },
        variant: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/variant`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/variant`,
          },
        },
        'subscription-items': {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/subscription-items`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/subscription-items`,
          },
        },
        'subscription-invoices': {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/subscription-invoices`,
            self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}/relationships/subscription-invoices`,
          },
        },
      },
      links: {
        self: `https://api.lemonsqueezy.com/v1/subscriptions/${subId}`,
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Invoice event payload (data.type = "subscription-invoices")
// This is what subscription_payment_* events actually send.
// Exactly matches: https://docs.lemonsqueezy.com/api/subscription-invoices/the-subscription-invoice-object
// ---------------------------------------------------------------------------
function buildInvoicePayload(eventName, userId, overrides = {}) {
  const now = lsTimestamp(0);
  const invoiceId = String(overrides.invoiceId || '500001');
  const subscriptionId = overrides.subscriptionId || 999001;
  const invoiceStatus = overrides.invoiceStatus || 'paid';
  const subtotal = overrides.subtotal || 999;
  const total = overrides.total || 999;
  const tax = overrides.tax || 0;
  const discountTotal = overrides.discountTotal || 0;
  const refundedAmount = overrides.refundedAmount || 0;

  return {
    meta: {
      event_name: eventName,
      ...(userId ? { custom_data: { user_id: String(userId) } } : {}),
    },
    data: {
      type: 'subscription-invoices',
      id: invoiceId,
      attributes: {
        store_id: 342696,
        subscription_id: subscriptionId,
        customer_id: 800001,
        user_name: TEST_DISPLAY_NAME,
        user_email: TEST_EMAIL,
        billing_reason: overrides.billingReason || 'renewal',
        card_brand: 'visa',
        card_last_four: '4242',
        currency: 'USD',
        currency_rate: '1.00000000',
        status: invoiceStatus,
        status_formatted: statusFormatted(invoiceStatus),
        refunded: overrides.refunded || false,
        refunded_at: overrides.refundedAt || null,
        subtotal: subtotal,
        discount_total: discountTotal,
        tax: tax,
        tax_inclusive: false,
        total: total,
        refunded_amount: refundedAmount,
        subtotal_usd: subtotal,
        discount_total_usd: discountTotal,
        tax_usd: tax,
        total_usd: total,
        refunded_amount_usd: refundedAmount,
        subtotal_formatted: overrides.subtotalFormatted || '$9.99',
        discount_total_formatted: '$0.00',
        tax_formatted: '$0.00',
        total_formatted: overrides.totalFormatted || '$9.99',
        refunded_amount_formatted: overrides.refundedAmountFormatted || '$0.00',
        urls: {
          invoice_url: overrides.invoiceUrl || `https://app.lemonsqueezy.com/my-orders/inv-${invoiceId}/subscription-invoice/${invoiceId}`,
        },
        created_at: overrides.createdAt || now,
        updated_at: overrides.updatedAt || now,
        test_mode: true,
        ...overrides.attributes,
      },
      relationships: {
        store: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}/store`,
            self: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}/relationships/store`,
          },
        },
        subscription: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}/subscription`,
            self: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}/relationships/subscription`,
          },
        },
        customer: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}/customer`,
            self: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}/relationships/customer`,
          },
        },
      },
      links: {
        self: `https://api.lemonsqueezy.com/v1/subscription-invoices/${invoiceId}`,
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Order event payload (data.type = "orders")
// Exactly matches: https://docs.lemonsqueezy.com/api/orders/the-order-object
// ---------------------------------------------------------------------------
function buildOrderPayload(eventName, userId, overrides = {}) {
  const now = lsTimestamp(0);
  const orderId = String(overrides.orderId || '700001');
  const total = overrides.total || 999;
  const subtotal = overrides.subtotal || total;
  const tax = overrides.tax || 0;
  const refundedAmount = overrides.refundedAmount || 0;

  return {
    meta: {
      event_name: eventName,
      custom_data: { user_id: String(userId) },
    },
    data: {
      type: 'orders',
      id: orderId,
      attributes: {
        store_id: 342696,
        customer_id: 800001,
        identifier: `test-${orderId}-${Date.now()}`,
        order_number: Number(orderId),
        user_name: TEST_DISPLAY_NAME,
        user_email: TEST_EMAIL,
        currency: 'USD',
        currency_rate: '1.0000',
        subtotal: subtotal,
        setup_fee: 0,
        discount_total: 0,
        tax: tax,
        total: total,
        refunded_amount: refundedAmount,
        subtotal_usd: subtotal,
        setup_fee_usd: 0,
        discount_total_usd: 0,
        tax_usd: tax,
        total_usd: total,
        refunded_amount_usd: refundedAmount,
        tax_name: null,
        tax_rate: '0.00',
        tax_inclusive: false,
        status: overrides.status || 'paid',
        status_formatted: statusFormatted(overrides.status || 'paid'),
        refunded: overrides.refunded || false,
        refunded_at: overrides.refundedAt || null,
        subtotal_formatted: '$9.99',
        setup_fee_formatted: '$0.00',
        discount_total_formatted: '$0.00',
        tax_formatted: '$0.00',
        total_formatted: overrides.totalFormatted || '$9.99',
        refunded_amount_formatted: overrides.refundedAmountFormatted || '$0.00',
        first_order_item: {
          id: 890001,
          order_id: Number(orderId),
          product_id: 400001,
          variant_id: Number(VARIANT_PRO),
          product_name: 'Inter Pro',
          variant_name: 'Pro Monthly',
          price: total,
          created_at: now,
          updated_at: now,
          test_mode: true,
        },
        urls: {
          receipt: `https://app.lemonsqueezy.com/my-orders/${orderId}?signature=test`,
        },
        created_at: now,
        updated_at: overrides.updatedAt || now,
        test_mode: true,
        ...overrides.attributes,
      },
      relationships: {
        store: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/orders/${orderId}/store`,
            self: `https://api.lemonsqueezy.com/v1/orders/${orderId}/relationships/store`,
          },
        },
        customer: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/orders/${orderId}/customer`,
            self: `https://api.lemonsqueezy.com/v1/orders/${orderId}/relationships/customer`,
          },
        },
        'order-items': {
          links: {
            related: `https://api.lemonsqueezy.com/v1/orders/${orderId}/order-items`,
            self: `https://api.lemonsqueezy.com/v1/orders/${orderId}/relationships/order-items`,
          },
        },
        subscriptions: {
          links: {
            related: `https://api.lemonsqueezy.com/v1/orders/${orderId}/subscriptions`,
            self: `https://api.lemonsqueezy.com/v1/orders/${orderId}/relationships/subscriptions`,
          },
        },
        'license-keys': {
          links: {
            related: `https://api.lemonsqueezy.com/v1/orders/${orderId}/license-keys`,
            self: `https://api.lemonsqueezy.com/v1/orders/${orderId}/relationships/license-keys`,
          },
        },
        'discount-redemptions': {
          links: {
            related: `https://api.lemonsqueezy.com/v1/orders/${orderId}/discount-redemptions`,
            self: `https://api.lemonsqueezy.com/v1/orders/${orderId}/relationships/discount-redemptions`,
          },
        },
      },
      links: {
        self: `https://api.lemonsqueezy.com/v1/orders/${orderId}`,
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------
let passed = 0;
let failed = 0;

function assert(condition, label) {
  if (condition) {
    passed++;
    console.log(`  \u2705 ${label}`);
  } else {
    failed++;
    console.error(`  \u274C ${label}`);
  }
}

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
async function run() {
  console.log('\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550');
  console.log('  Lemon Squeezy Billing Integration Tests');
  console.log('\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n');

  // ── Step 0: Health check ──────────────────────────────────────────────
  console.log('\u25B8 Step 0: Server health check');
  const health = await request('GET', '/health');
  assert(health.status === 200, `GET /health \u2192 ${health.status}`);
  if (health.status !== 200) {
    console.error('\n  Server not running. Start it with: node index.js\n');
    process.exit(1);
  }

  // ── Step 1: Register a test user ──────────────────────────────────────
  console.log('\n\u25B8 Step 1: Register test user');
  const reg = await request('POST', '/auth/register', {
    email: TEST_EMAIL,
    password: TEST_PASSWORD,
    displayName: TEST_DISPLAY_NAME,
  });
  assert(reg.status === 201, `POST /auth/register \u2192 ${reg.status}`);
  assert(reg.body?.user?.id != null, `userId = ${reg.body?.user?.id}`);
  const userId = reg.body?.user?.id;
  const accessToken = reg.body?.accessToken;

  if (!userId || !accessToken) {
    console.error('\n  Registration failed. Cannot continue.\n');
    process.exit(1);
  }

  // ── Step 2: Webhook rejects unsigned requests ────────────────────────
  console.log('\n\u25B8 Step 2: Webhook signature verification');
  const noSig = await request('POST', '/webhooks/lemonsqueezy', '{"test": true}', {
    'Content-Type': 'application/json',
  });
  assert(noSig.status === 401, `No signature \u2192 401 (got ${noSig.status})`);

  const badSig = await request('POST', '/webhooks/lemonsqueezy', '{"test": true}', {
    'Content-Type': 'application/json',
    'X-Signature': 'deadbeef',
  });
  assert(badSig.status === 401, `Bad signature \u2192 401 (got ${badSig.status})`);

  // ── Step 3: subscription_created (new Pro subscription) ───────────────
  console.log('\n\u25B8 Step 3: subscription_created \u2192 user becomes Pro');
  const createPayload = buildSubscriptionPayload('subscription_created', userId, {
    variantId: Number(VARIANT_PRO),
    status: 'active',
  });
  const createRes = await sendWebhook(createPayload);
  assert(createRes.status === 200, `Webhook \u2192 ${createRes.status}`);
  assert(createRes.body?.received === true, `received = ${createRes.body?.received}`);

  // Verify DB state via portal endpoint
  const portal1 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal1.status === 200, `Portal URL \u2192 ${portal1.status}`);
  assert(portal1.body?.subscriptionStatus === 'active', `status = ${portal1.body?.subscriptionStatus}`);
  assert(portal1.body?.portalUrl != null, `portalUrl present`);

  // ── Step 4: Idempotency — same event replayed ────────────────────────
  console.log('\n\u25B8 Step 4: Idempotency (replay same event)');
  const dupRes = await sendWebhook(createPayload);
  assert(dupRes.status === 200, `Duplicate \u2192 ${dupRes.status}`);
  assert(dupRes.body?.duplicate === true, `duplicate = ${dupRes.body?.duplicate}`);

  // ── Step 5: subscription_payment_success (invoice payload) ────────────
  // KEY TEST: This sends an Invoice object, NOT a Subscription object.
  // The handler should NOT crash, and should NOT change subscription_status.
  console.log('\n\u25B8 Step 5: subscription_payment_success (invoice payload)');
  const paySuccessPayload = buildInvoicePayload('subscription_payment_success', userId, {
    subscriptionId: 999001,
    invoiceId: '500001',
    billingReason: 'renewal',
    invoiceStatus: 'paid',
    updatedAt: new Date(Date.now() + 1000).toISOString(),
  });
  const paySuccessRes = await sendWebhook(paySuccessPayload);
  assert(paySuccessRes.status === 200, `Invoice webhook \u2192 ${paySuccessRes.status}`);

  // Status should still be 'active' (payment events don't change status)
  const portal2 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal2.body?.subscriptionStatus === 'active', `status still active = ${portal2.body?.subscriptionStatus}`);

  // ── Step 6: subscription_payment_failed (invoice payload) ─────────────
  // Simulates card decline on renewal. Invoice event should just log it.
  // The accompanying subscription_updated sets past_due.
  console.log('\n\u25B8 Step 6: Payment failure flow (invoice + subscription_updated)');

  // 6a: Invoice event (logs, does NOT change status)
  const payFailPayload = buildInvoicePayload('subscription_payment_failed', userId, {
    subscriptionId: 999001,
    invoiceId: '500002',
    invoiceStatus: 'pending',
    updatedAt: new Date(Date.now() + 2000).toISOString(),
  });
  const payFailRes = await sendWebhook(payFailPayload);
  assert(payFailRes.status === 200, `Invoice webhook \u2192 ${payFailRes.status}`);

  // 6b: subscription_updated with status=past_due (the canonical status change)
  const pastDuePayload = buildSubscriptionPayload('subscription_updated', userId, {
    status: 'past_due',
    updatedAt: new Date(Date.now() + 2500).toISOString(),
  });
  const pastDueRes = await sendWebhook(pastDuePayload);
  assert(pastDueRes.status === 200, `subscription_updated[past_due] \u2192 ${pastDueRes.status}`);

  const portal3 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal3.body?.subscriptionStatus === 'past_due', `status = ${portal3.body?.subscriptionStatus}`);

  // ── Step 7: past_due user should STILL have access ────────────────────
  // Per LS docs: "subscription will remain active and the customer
  // will continue to have access to the subscription's content"
  console.log('\n\u25B8 Step 7: past_due user retains access (LS retrying payment)');
  // The billing/portal-url endpoint worked above, confirming access isn't blocked.
  // Also verify the checkout endpoint works (requires auth but not tier gate)
  const checkAuth = await request('POST', '/billing/checkout', { variantId: VARIANT_PRO }, {
    Authorization: `Bearer ${accessToken}`,
  });
  // Should get either 200 (checkout URL) or some non-403 error
  assert(checkAuth.status !== 403, `past_due user not blocked from checkout (got ${checkAuth.status})`);

  // ── Step 8: subscription_payment_recovered (invoice) + _updated(active) ──
  console.log('\n\u25B8 Step 8: Payment recovery flow');

  // 8a: subscription_payment_recovered (invoice)
  const payRecoveredPayload = buildInvoicePayload('subscription_payment_recovered', userId, {
    subscriptionId: 999001,
    invoiceId: '500003',
    invoiceStatus: 'paid',
    updatedAt: new Date(Date.now() + 3000).toISOString(),
  });
  const payRecoveredRes = await sendWebhook(payRecoveredPayload);
  assert(payRecoveredRes.status === 200, `Invoice webhook \u2192 ${payRecoveredRes.status}`);

  // 8b: subscription_updated back to active
  const activePayload = buildSubscriptionPayload('subscription_updated', userId, {
    status: 'active',
    updatedAt: new Date(Date.now() + 3500).toISOString(),
  });
  const activeRes = await sendWebhook(activePayload);
  assert(activeRes.status === 200, `subscription_updated[active] \u2192 ${activeRes.status}`);

  const portal4 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal4.body?.subscriptionStatus === 'active', `status = ${portal4.body?.subscriptionStatus}`);

  // ── Step 9: subscription_cancelled + _updated(cancelled) ──────────────
  console.log('\n\u25B8 Step 9: Cancellation with grace period');
  const endsAt = new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString();

  const cancelPayload = buildSubscriptionPayload('subscription_cancelled', userId, {
    status: 'cancelled',
    endsAt,
    updatedAt: new Date(Date.now() + 4000).toISOString(),
    attributes: { cancelled: true },
  });
  const cancelRes = await sendWebhook(cancelPayload);
  assert(cancelRes.status === 200, `subscription_cancelled \u2192 ${cancelRes.status}`);

  const cancelUpdatedPayload = buildSubscriptionPayload('subscription_updated', userId, {
    status: 'cancelled',
    endsAt,
    updatedAt: new Date(Date.now() + 4500).toISOString(),
    attributes: { cancelled: true },
  });
  const cancelUpdatedRes = await sendWebhook(cancelUpdatedPayload);
  assert(cancelUpdatedRes.status === 200, `subscription_updated[cancelled] \u2192 ${cancelUpdatedRes.status}`);

  const portal5 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal5.body?.subscriptionStatus === 'cancelled', `status = ${portal5.body?.subscriptionStatus}`);

  // ── Step 10: subscription_resumed (cancelled → active) ────────────────
  console.log('\n\u25B8 Step 10: Resume cancelled subscription (cancelled \u2192 active)');
  const resumePayload = buildSubscriptionPayload('subscription_resumed', userId, {
    status: 'active',
    updatedAt: new Date(Date.now() + 5000).toISOString(),
  });
  const resumeRes = await sendWebhook(resumePayload);
  assert(resumeRes.status === 200, `subscription_resumed \u2192 ${resumeRes.status}`);

  const portal6 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal6.body?.subscriptionStatus === 'active', `status = ${portal6.body?.subscriptionStatus}`);

  // ── Step 11: subscription_paused → _unpaused ──────────────────────────
  console.log('\n\u25B8 Step 11: Pause and unpause');

  const pausePayload = buildSubscriptionPayload('subscription_paused', userId, {
    status: 'paused',
    updatedAt: new Date(Date.now() + 6000).toISOString(),
    pause: { mode: 'void', resumes_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString() },
    attributes: { variant_id: Number(VARIANT_PRO), product_id: 400001, customer_id: 800001 },
  });
  const pauseRes = await sendWebhook(pausePayload);
  assert(pauseRes.status === 200, `subscription_paused \u2192 ${pauseRes.status}`);

  const portal7 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal7.body?.subscriptionStatus === 'paused', `status = ${portal7.body?.subscriptionStatus}`);

  const unpausePayload = buildSubscriptionPayload('subscription_unpaused', userId, {
    status: 'active',
    updatedAt: new Date(Date.now() + 7000).toISOString(),
    attributes: { variant_id: Number(VARIANT_PRO), product_id: 400001, customer_id: 800001 },
  });
  const unpauseRes = await sendWebhook(unpausePayload);
  assert(unpauseRes.status === 200, `subscription_unpaused \u2192 ${unpauseRes.status}`);

  const portal8 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal8.body?.subscriptionStatus === 'active', `status = ${portal8.body?.subscriptionStatus}`);

  // ── Step 12: Full dunning flow (past_due → unpaid → expired) ──────────
  console.log('\n\u25B8 Step 12: Full dunning flow (past_due \u2192 unpaid \u2192 expired)');

  // 12a: Payment fails → past_due
  const pastDue12Res = await sendWebhook(buildSubscriptionPayload('subscription_updated', userId, {
    status: 'past_due',
    updatedAt: new Date(Date.now() + 8000).toISOString(),
  }));
  assert(pastDue12Res.status === 200, `subscription_updated[past_due] → ${pastDue12Res.status}`);

  // 12b: All retries fail → unpaid
  const unpaidPayload = buildSubscriptionPayload('subscription_updated', userId, {
    status: 'unpaid',
    updatedAt: new Date(Date.now() + 9000).toISOString(),
  });
  const unpaidRes = await sendWebhook(unpaidPayload);
  assert(unpaidRes.status === 200, `subscription_updated[unpaid] \u2192 ${unpaidRes.status}`);

  const portal9 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal9.body?.subscriptionStatus === 'unpaid', `status = ${portal9.body?.subscriptionStatus}`);

  // 12c: Dunning expires → expired
  const expirePayload = buildSubscriptionPayload('subscription_expired', userId, {
    status: 'expired',
    endsAt: new Date().toISOString(),
    updatedAt: new Date(Date.now() + 10000).toISOString(),
  });
  const expireRes = await sendWebhook(expirePayload);
  assert(expireRes.status === 200, `subscription_expired \u2192 ${expireRes.status}`);

  const portal10 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(
    portal10.body?.subscriptionStatus === 'expired' || portal10.status === 404,
    `status = ${portal10.body?.subscriptionStatus || 'no billing'}`
  );

  // ── Step 13: Re-subscribe with Pro+ (expired → active) ────────────────
  console.log('\n\u25B8 Step 13: Re-subscribe with Pro+ (expired \u2192 active)');
  const resubPayload = buildSubscriptionPayload('subscription_created', userId, {
    subscriptionId: '999002',
    variantId: Number(VARIANT_PRO_PLUS),
    status: 'active',
    updatedAt: new Date(Date.now() + 11000).toISOString(),
  });
  const resubRes = await sendWebhook(resubPayload);
  assert(resubRes.status === 200, `subscription_created \u2192 ${resubRes.status}`);

  const portal11 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal11.body?.subscriptionStatus === 'active', `status = ${portal11.body?.subscriptionStatus}`);

  // ── Step 14: subscription_payment_refunded (invoice event) ────────────
  console.log('\n\u25B8 Step 14: subscription_payment_refunded (invoice event)');
  const refundPayload = buildInvoicePayload('subscription_payment_refunded', userId, {
    subscriptionId: 999002,
    invoiceId: '500004',
    invoiceStatus: 'refunded',
    refunded: true,
    refundedAmount: 999,
    refundedAmountFormatted: '$9.99',
    updatedAt: new Date(Date.now() + 12000).toISOString(),
  });
  const refundRes = await sendWebhook(refundPayload);
  assert(refundRes.status === 200, `Invoice[refunded] \u2192 ${refundRes.status}`);

  // Status should still be active (refund event doesn't change status)
  const portal12 = await request('GET', '/billing/portal-url', null, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(portal12.body?.subscriptionStatus === 'active', `status unchanged after refund = ${portal12.body?.subscriptionStatus}`);

  // ── Step 15: Invoice event without custom_data (lookup via ls_subscription_id) ──
  console.log('\n\u25B8 Step 15: Invoice lookup by ls_subscription_id (no custom_data)');
  const noCustomDataPayload = buildInvoicePayload('subscription_payment_success', null, {
    subscriptionId: 999002,
    invoiceId: '500005',
    updatedAt: new Date(Date.now() + 13000).toISOString(),
  });
  const noCustomRes = await sendWebhook(noCustomDataPayload);
  assert(noCustomRes.status === 200, `Invoice without custom_data \u2192 ${noCustomRes.status}`);

  // ── Step 16: Plan change via subscription_updated ─────────────────────
  console.log('\n\u25B8 Step 16: Plan change (Pro+ \u2192 Pro via subscription_updated)');
  const planChangePayload = buildSubscriptionPayload('subscription_updated', userId, {
    subscriptionId: '999002',
    variantId: Number(VARIANT_PRO),
    status: 'active',
    updatedAt: new Date(Date.now() + 14000).toISOString(),
  });
  const planChangeRes = await sendWebhook(planChangePayload);
  assert(planChangeRes.status === 200, `subscription_updated[plan change] \u2192 ${planChangeRes.status}`);

  // ── Step 17: Order events ─────────────────────────────────────────────
  console.log('\n\u25B8 Step 17: Order events (logged only)');
  const orderPayload = buildOrderPayload('order_created', userId, {
    updatedAt: new Date(Date.now() + 15000).toISOString(),
  });
  const orderRes = await sendWebhook(orderPayload);
  assert(orderRes.status === 200, `order_created \u2192 ${orderRes.status}`);

  const orderRefundPayload = buildOrderPayload('order_refunded', userId, {
    orderId: '700002',
    refundedAmount: 999,
    refundedAmountFormatted: '$9.99',
    updatedAt: new Date(Date.now() + 16000).toISOString(),
  });
  const orderRefundRes = await sendWebhook(orderRefundPayload);
  assert(orderRefundRes.status === 200, `order_refunded \u2192 ${orderRefundRes.status}`);

  // ── Step 18: Checkout endpoint validation ─────────────────────────────
  console.log('\n\u25B8 Step 18: Checkout endpoint validation');
  const noAuth = await request('POST', '/billing/checkout', { variantId: VARIANT_PRO });
  assert(noAuth.status === 401, `No auth \u2192 401 (got ${noAuth.status})`);

  const badVariant = await request('POST', '/billing/checkout', { variantId: '999999' }, {
    Authorization: `Bearer ${accessToken}`,
  });
  assert(badVariant.status === 400, `Invalid variant \u2192 400 (got ${badVariant.status})`);
  assert(badVariant.body?.code === 'INVALID_VARIANT', `code = ${badVariant.body?.code}`);

  // Valid checkout — calls the real LS API
  console.log('\n\u25B8 Step 19: Real checkout URL generation (calls LS API)');
  const checkout = await request('POST', '/billing/checkout', { variantId: VARIANT_PRO }, {
    Authorization: `Bearer ${accessToken}`,
  });
  if (checkout.status === 200 && checkout.body?.url) {
    assert(true, `Checkout URL generated: ${checkout.body.url.slice(0, 60)}...`);
  } else if (checkout.status === 503) {
    console.log('  \u23ED\uFE0F  Billing not configured (API key missing) \u2014 skipped');
  } else {
    assert(false, `Checkout failed: ${checkout.status} \u2014 ${JSON.stringify(checkout.body)}`);
  }

  // ── Summary ───────────────────────────────────────────────────────────
  console.log('\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550');
  console.log(`  Results: ${passed} passed, ${failed} failed, ${passed + failed} total`);
  console.log('\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n');

  process.exit(failed > 0 ? 1 : 0);
}

run().catch((err) => {
  console.error('\nFatal error:', err.message);
  process.exit(1);
});
