// ============================================================================
// billing.js — Lemon Squeezy Subscription Lifecycle Webhooks (Phase C)
//
// Mounted at: POST /webhooks/lemonsqueezy
// CRITICAL: Must be mounted with express.raw() BEFORE express.json() in index.js:
//   app.post('/webhooks/lemonsqueezy', express.raw({ type: 'application/json' }), require('./billing'));
//   app.use(express.json());  // <-- AFTER
//
// LS webhook payloads come in TWO different shapes:
//   1. Subscription events → data.type = "subscriptions"
//      (subscription_created, _updated, _cancelled, _expired, _paused, _unpaused, _resumed)
//      Fields: variant_id, customer_id, status, renews_at, ends_at, urls, trial_ends_at
//
//   2. Invoice events → data.type = "subscription-invoices"
//      (subscription_payment_success, _payment_failed, _payment_recovered, _payment_refunded)
//      Fields: subscription_id, customer_id, billing_reason, total, currency, status (paid/void/refunded)
//      Does NOT have: variant_id, renews_at, ends_at, urls.customer_portal
//
// Status management strategy:
//   - subscription_updated is the canonical sync (LS fires it alongside every other event)
//   - Invoice events do NOT change subscription_status (they log the payment and that's it)
//   - For robustness, subscription_* events also set status directly (in case _updated is lost)
//
// LS dunning lifecycle:
//   active → (payment fails) → past_due → (4 retries over 2 weeks) → unpaid → (dunning) → expired
//   Per LS docs, past_due users KEEP access. Only unpaid/expired should restrict.
// ============================================================================

const db     = require('./db');
const crypto = require('crypto');

const LEMONSQUEEZY_WEBHOOK_SECRET = process.env.LEMONSQUEEZY_WEBHOOK_SECRET;
if (!LEMONSQUEEZY_WEBHOOK_SECRET || LEMONSQUEEZY_WEBHOOK_SECRET.length < 6) {
  console.warn('[billing] LEMONSQUEEZY_WEBHOOK_SECRET not set — webhook endpoint will reject all requests.');
}

// ---------------------------------------------------------------------------
// Variant ID → tier mapping
// Found in: LS Dashboard → Store → Products → Variants, or via API
// ---------------------------------------------------------------------------
const VARIANT_ID_TO_TIER = {
  '1516865': 'pro+',  // Pro+ (test)
  '1516868': 'pro',   // Pro  (test)
};

// Statuses that grant paid-tier access even without a confirmed 'active' subscription
const TRIAL_GRANTS_TIER = { on_trial: 'pro' };

// ---------------------------------------------------------------------------
// Valid state transitions — logged but NOT enforced before DB updates.
// LS is authoritative: events may arrive out of order (e.g. subscription_updated
// before subscription_created on first purchase). Anomalies are warned, but the
function validateTransition(from, to) {
  if (!VALID_TRANSITIONS[from]?.includes(to)) {
    console.error(`[billing] Invalid subscription transition: ${from} → ${to}`);
    throw new Error(`Invalid subscription transition: ${from} → ${to}`);
  }
  return true;
}
//   unpaid → active | cancelled | expired       (customer pays, cancels, or dunning ends)
//   cancelled → active | expired                (user resumes, or grace period ends)
//   expired → active | on_trial                 (user re-subscribes)
//   paused → active                             (user unpauses)
// ---------------------------------------------------------------------------
const VALID_TRANSITIONS = {
  none:      ['on_trial', 'active'],
  on_trial:  ['active', 'cancelled'],
  active:    ['past_due', 'cancelled', 'paused'],
  past_due:  ['active', 'unpaid', 'cancelled'],
  unpaid:    ['active', 'cancelled', 'expired'],
  cancelled: ['active', 'expired'],
  expired:   ['active', 'on_trial'],
  paused:    ['active'],
};

function validateTransition(from, to) {
  if (from === to) return true; // no-op transition (e.g. subscription_updated echoing current status)
  if (!VALID_TRANSITIONS[from]?.includes(to)) {
    console.warn(`[billing] Unexpected subscription transition: ${from} → ${to} (proceeding anyway — LS is authoritative)`);
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Idempotency — prevent double-processing of replayed webhook events
// ---------------------------------------------------------------------------
function generateEventId(eventName, dataId, timestamp, rawBody) {
  const ts = timestamp ? new Date(timestamp).toISOString() : new Date().toISOString();
  // Include a SHA-256 of the raw payload as extra entropy so two different events
  // arriving in the same millisecond for the same subscription cannot collide.
  // Using the payload hash (not a random nonce) keeps the ID deterministic, which
  // means replayed identical payloads still deduplicate correctly.
  const bodyHash = crypto.createHash('sha256').update(rawBody).digest('hex');
  const raw = `${eventName}:${dataId}:${ts}:${bodyHash}`;
  return crypto.createHash('sha256').update(raw).digest('hex').slice(0, 64);
}

async function isEventAlreadyProcessed(eventId) {
  const result = await db.query(
    'SELECT 1 FROM processed_webhook_events WHERE event_id = $1',
    [eventId]
  );
  return result.rows.length > 0;
}

async function markEventProcessed(eventId, eventType) {
  await db.query(
    `INSERT INTO processed_webhook_events (event_id, event_type) VALUES ($1, $2)
     ON CONFLICT (event_id) DO NOTHING`,
    [eventId, eventType]
  );
}

// ---------------------------------------------------------------------------
// Webhook signature verification — HMAC-SHA256 (Lemon Squeezy)
// ---------------------------------------------------------------------------
function verifySignature(rawBody, signatureHeader) {
  if (!LEMONSQUEEZY_WEBHOOK_SECRET || LEMONSQUEEZY_WEBHOOK_SECRET.length < 6) return false;
  if (!signatureHeader) return false;

  const hmac = crypto.createHmac('sha256', LEMONSQUEEZY_WEBHOOK_SECRET);
  const digest = Buffer.from(hmac.update(rawBody).digest('hex'), 'utf8');
  const signature = Buffer.from(signatureHeader, 'utf8');

  if (digest.length !== signature.length) return false;
  return crypto.timingSafeEqual(digest, signature);
}

// ---------------------------------------------------------------------------
// Detect payload type from event name
// ---------------------------------------------------------------------------
const INVOICE_EVENTS = new Set([
  'subscription_payment_success',
  'subscription_payment_failed',
  'subscription_payment_recovered',
  'subscription_payment_refunded',
]);

function isInvoiceEvent(eventName) {
  return INVOICE_EVENTS.has(eventName);
}

// ---------------------------------------------------------------------------
// Webhook handler — Express middleware (req.body is a raw Buffer here)
// ---------------------------------------------------------------------------
module.exports = async function billingWebhook(req, res) {
  // Log non-PII structural fields only — never log user_email, user_name, card details, etc.
  try {
    const raw = req.body instanceof Buffer ? req.body.toString('utf8') : String(req.body);
    const parsed = JSON.parse(raw);
    const attrs = parsed.data?.attributes ?? {};
    console.log('[billing] Incoming LS webhook:', {
      event_name:      parsed.meta?.event_name,
      data_type:       parsed.data?.type,
      data_id:         parsed.data?.id,
      status:          attrs.status,
      subscription_id: attrs.subscription_id,
      variant_id:      attrs.variant_id,
      billing_reason:  attrs.billing_reason,
    });
  } catch (e) {
    console.log('[billing] Incoming LS webhook: <unprintable payload>', e.message);
  }

  // Step 1: Verify webhook signature
  const isValid = verifySignature(req.body, req.get('X-Signature'));
  if (!isValid) {
    console.error('[billing] Webhook signature verification failed');
    return res.status(401).json({ error: 'Invalid webhook signature' });
  }

  // Step 2: Parse the verified payload
  let payload;
  try {
    payload = JSON.parse(req.body.toString('utf8'));
  } catch (err) {
    console.error('[billing] Webhook payload parse error:', err.message);
    return res.status(400).json({ error: 'Invalid JSON payload' });
  }

  const eventName = payload.meta?.event_name;
  const attrs = payload.data?.attributes;
  const dataId = String(payload.data?.id || '');

  if (!eventName || !attrs) {
    console.error('[billing] Webhook missing event_name or data.attributes');
    return res.status(400).json({ error: 'Invalid webhook payload structure' });
  }

  // Step 3: Idempotency check (dataId is subscription ID or invoice ID depending on type)
  const eventId = generateEventId(eventName, dataId, attrs.updated_at || attrs.created_at, req.body);
  if (await isEventAlreadyProcessed(eventId)) {
    return res.status(200).json({ received: true, duplicate: true });
  }

  // Step 4: Process the event
  try {
    await handleEvent(eventName, payload);
    await markEventProcessed(eventId, eventName);
    res.status(200).json({ received: true });
  } catch (err) {
    console.error(`[billing] Event handler failed: ${eventName}`, err.message);
    res.status(500).json({ error: 'Event processing failed' });
  }
};

// ---------------------------------------------------------------------------
// User resolution — three lookup strategies depending on payload type
//
// For Subscription events: custom_data.user_id → ls_customer_id
// For Invoice events:      custom_data.user_id → ls_subscription_id → ls_customer_id
//
// Invoice payloads carry subscription_id (not the subscription's own fields),
// so we match it against users.ls_subscription_id.
// ---------------------------------------------------------------------------
async function resolveUser(payload) {
  const customData = payload.meta?.custom_data;
  const attrs = payload.data?.attributes;

  // 1. Primary: custom_data.user_id from checkout
  if (customData?.user_id) {
    const result = await db.query(
      'SELECT id, tier, subscription_status FROM users WHERE id = $1 AND deleted_at IS NULL',
      [customData.user_id]
    );
    if (result.rows.length > 0) return result.rows[0];
  }

  // 2. For invoice events: match subscription_id → users.ls_subscription_id
  const subIdFromInvoice = attrs?.subscription_id;
  if (subIdFromInvoice) {
    const result = await db.query(
      'SELECT id, tier, subscription_status FROM users WHERE ls_subscription_id = $1 AND deleted_at IS NULL',
      [String(subIdFromInvoice)]
    );
    if (result.rows.length > 0) return result.rows[0];
  }

  // 3. Fallback: customer_id → users.ls_customer_id
  const customerId = attrs?.customer_id;
  if (customerId) {
    const result = await db.query(
      'SELECT id, tier, subscription_status FROM users WHERE ls_customer_id = $1 AND deleted_at IS NULL',
      [String(customerId)]
    );
    if (result.rows.length > 0) return result.rows[0];
  }

  return null;
}

// ---------------------------------------------------------------------------
// Tier resolution from variant ID
// ---------------------------------------------------------------------------
function resolveTier(variantId) {
  return VARIANT_ID_TO_TIER[String(variantId)] ?? 'free';
}

// ---------------------------------------------------------------------------
// Audit trail helper (fire-and-forget)
// ---------------------------------------------------------------------------
function auditTierChange(userId, fromTier, toTier, reason, eventId) {
  if (fromTier === toTier) return;
  db.query(
    `INSERT INTO user_tier_history (user_id, from_tier, to_tier, reason, event_id)
     VALUES ($1, $2, $3, $4, $5)`,
    [userId, fromTier, toTier, reason, eventId]
  ).catch(err => console.error('[billing] audit log failed:', err.message));
}

// ---------------------------------------------------------------------------
// Event dispatch
// ---------------------------------------------------------------------------
async function handleEvent(eventName, payload) {
  if (isInvoiceEvent(eventName)) {
    return handleInvoiceEvent(eventName, payload);
  }

  const sub = payload.data.attributes;
  const subscriptionId = String(payload.data.id);

  switch (eventName) {

    // ── subscription_created ──────────────────────────────────────────────
    // Fires: first purchase or re-subscribe after expiry
    // Always accompanied by order_created + subscription_payment_success
    case 'subscription_created': {
      const user = await resolveUser(payload);
      if (!user) {
        throw new Error(`subscription_created: user not found (sub_id=${subscriptionId}, custom_data_user=${payload.meta?.custom_data?.user_id})`);
      }

      const tier = resolveTier(sub.variant_id);
      const newStatus = sub.status === 'on_trial' ? 'on_trial' : 'active';
      validateTransition(user.subscription_status || 'none', newStatus);

      await db.query(
        `UPDATE users
         SET tier = $1,
             subscription_status = $2,
             ls_subscription_id = $3,
             ls_customer_id = $4,
             ls_variant_id = $5,
             ls_product_id = $6,
             trial_ends_at = $7,
             current_period_ends_at = $8,
             grace_until = NULL,
             ls_portal_url = $9,
             ls_update_payment_url = $10,
             updated_at = NOW()
         WHERE id = $11`,
        [
          tier,
          newStatus,
          subscriptionId,
          String(sub.customer_id),
          String(sub.variant_id),
          String(sub.product_id),
          sub.trial_ends_at || null,
          sub.renews_at || null,
          sub.urls?.customer_portal || null,
          sub.urls?.update_payment_method || null,
          user.id,
        ]
      );

      auditTierChange(user.id, user.tier, tier, 'ls_subscription_created', subscriptionId);
      console.log(`[billing] subscription_created: user=${user.id} tier=${tier} status=${newStatus}`);
      break;
    }

    // ── subscription_updated (CANONICAL SYNC) ─────────────────────────────
    // Fires alongside EVERY other subscription event. LS docs:
    //   "This event can be used as a catch-all to make sure you always
    //    have access to the latest subscription data."
    //
    // Handles: renewals, cancellations, expirations, payment status changes,
    //          plan changes (variant_id swap), pause/unpause, trial→active
    case 'subscription_updated': {
      const user = await resolveUser(payload);
      if (!user) {
        throw new Error(`subscription_updated: user not found (sub_id=${subscriptionId})`);
      }

      const newStatus = sub.status;
      const previousStatus = user.subscription_status || 'none';
      validateTransition(previousStatus, newStatus);

      // Always sync portal + payment method URLs (they are pre-signed, 24h expiry)
      const portalUrl = sub.urls?.customer_portal || null;
      const updatePaymentUrl = sub.urls?.update_payment_method || null;

      // ── expired: terminal state, downgrade to free ──
      if (newStatus === 'expired') {
        await db.query(
          `UPDATE users
           SET tier = 'free',
               subscription_status = 'expired',
               ls_subscription_id = NULL,
               ls_variant_id = NULL,
               ls_product_id = NULL,
               grace_until = NULL,
               current_period_ends_at = NULL,
               trial_ends_at = NULL,
               ls_portal_url = $1,
               ls_update_payment_url = NULL,
               updated_at = NOW()
           WHERE id = $2`,
          [portalUrl, user.id]
        );
        auditTierChange(user.id, user.tier, 'free', 'ls_subscription_expired', subscriptionId);
        console.log(`[billing] subscription_updated[expired]: user=${user.id} downgraded from ${user.tier}`);
        break;
      }

      // ── cancelled: user keeps access until ends_at (grace period) ──
      if (newStatus === 'cancelled') {
        await db.query(
          `UPDATE users
           SET subscription_status = 'cancelled',
               grace_until = $1,
               ls_portal_url = $2,
               ls_update_payment_url = $3,
               updated_at = NOW()
           WHERE id = $4`,
          [sub.ends_at || null, portalUrl, updatePaymentUrl, user.id]
        );
        console.log(`[billing] subscription_updated[cancelled]: user=${user.id} grace_until=${sub.ends_at}`);
        break;
      }

      // ── paused: payment collection halted ──
      if (newStatus === 'paused') {
        await db.query(
          `UPDATE users
           SET subscription_status = 'paused',
               ls_portal_url = $1,
               ls_update_payment_url = $2,
               updated_at = NOW()
           WHERE id = $3`,
          [portalUrl, updatePaymentUrl, user.id]
        );
        console.log(`[billing] subscription_updated[paused]: user=${user.id}`);
        break;
      }

      // ── unpaid: all payment retries failed, dunning begins ──
      // User should now lose access (unlike past_due which keeps access)
      if (newStatus === 'unpaid') {
        await db.query(
          `UPDATE users
           SET subscription_status = 'unpaid',
               ls_portal_url = $1,
               ls_update_payment_url = $2,
               updated_at = NOW()
           WHERE id = $3`,
          [portalUrl, updatePaymentUrl, user.id]
        );
        console.log(`[billing] subscription_updated[unpaid]: user=${user.id} — access restricted`);
        break;
      }

      // ── past_due: payment failed but LS is retrying ──
      // Per LS docs: "subscription will remain active and the customer
      // will continue to have access" — do NOT restrict access
      if (newStatus === 'past_due') {
        await db.query(
          `UPDATE users
           SET subscription_status = 'past_due',
               ls_portal_url = $1,
               ls_update_payment_url = $2,
               updated_at = NOW()
           WHERE id = $3`,
          [portalUrl, updatePaymentUrl, user.id]
        );
        console.log(`[billing] subscription_updated[past_due]: user=${user.id} — access retained (LS retrying)`);
        break;
      }

      // ── active / on_trial: full sync of tier + dates ──
      const tier = resolveTier(sub.variant_id);
      await db.query(
        `UPDATE users
         SET tier = $1,
             subscription_status = $2,
             ls_subscription_id = $3,
             ls_variant_id = $4,
             ls_product_id = $5,
             current_period_ends_at = $6,
             trial_ends_at = $7,
             grace_until = NULL,
             ls_portal_url = $8,
             ls_update_payment_url = $9,
             updated_at = NOW()
         WHERE id = $10`,
        [
          tier,
          newStatus,
          subscriptionId,
          String(sub.variant_id),
          String(sub.product_id),
          sub.renews_at || null,
          sub.trial_ends_at || null,
          portalUrl,
          updatePaymentUrl,
          user.id,
        ]
      );

      auditTierChange(user.id, user.tier, tier, 'ls_subscription_updated', subscriptionId);
      console.log(`[billing] subscription_updated[${newStatus}]: user=${user.id} tier=${tier}`);
      break;
    }

    // ── subscription_cancelled ────────────────────────────────────────────
    // User or store owner manually cancelled. Subscription enters grace period.
    // The user keeps access until ends_at. They can resume before then.
    // Always accompanied by subscription_updated.
    case 'subscription_cancelled': {
      const user = await resolveUser(payload);
      if (!user) throw new Error(`subscription_cancelled: user not found (sub_id=${subscriptionId})`);
      validateTransition(user.subscription_status || 'none', 'cancelled');

      await db.query(
        `UPDATE users
         SET subscription_status = 'cancelled',
             grace_until = $1,
             ls_portal_url = $2,
             ls_update_payment_url = $3,
             updated_at = NOW()
         WHERE id = $4`,
        [
          sub.ends_at || null,
          sub.urls?.customer_portal || null,
          sub.urls?.update_payment_method || null,
          user.id,
        ]
      );
      console.log(`[billing] subscription_cancelled: user=${user.id} ends_at=${sub.ends_at}`);
      break;
    }

    // ── subscription_expired ──────────────────────────────────────────────
    // Terminal state: cancelled grace period ended, or dunning finished for unpaid.
    // User loses all paid-tier access immediately.
    // Always accompanied by subscription_updated.
    case 'subscription_expired': {
      const user = await resolveUser(payload);
      if (!user) throw new Error(`subscription_expired: user not found (sub_id=${subscriptionId})`);

      const previousTier = user.tier;
      await db.query(
        `UPDATE users
         SET tier = 'free',
             subscription_status = 'expired',
             ls_subscription_id = NULL,
             ls_variant_id = NULL,
             ls_product_id = NULL,
             grace_until = NULL,
             current_period_ends_at = NULL,
             trial_ends_at = NULL,
             ls_update_payment_url = NULL,
             updated_at = NOW()
         WHERE id = $1`,
        [user.id]
      );

      auditTierChange(user.id, previousTier, 'free', 'ls_subscription_expired', subscriptionId);
      console.log(`[billing] subscription_expired: user=${user.id} downgraded from ${previousTier}`);
      break;
    }

    // ── subscription_paused ───────────────────────────────────────────────
    // Payment collection halted. User should not have access.
    // sub.pause.resumes_at tells when it auto-resumes (if set).
    // Always accompanied by subscription_updated.
    case 'subscription_paused': {
      const user = await resolveUser(payload);
      if (!user) throw new Error(`subscription_paused: user not found (sub_id=${subscriptionId})`);
      validateTransition(user.subscription_status || 'none', 'paused');

      await db.query(
        `UPDATE users
         SET subscription_status = 'paused',
             ls_portal_url = $1,
             ls_update_payment_url = $2,
             updated_at = NOW()
         WHERE id = $3`,
        [sub.urls?.customer_portal || null, sub.urls?.update_payment_method || null, user.id]
      );
      const resumesAt = sub.pause?.resumes_at || 'manual';
      console.log(`[billing] subscription_paused: user=${user.id} resumes_at=${resumesAt}`);
      break;
    }

    // ── subscription_unpaused ─────────────────────────────────────────────
    // Payment collection resumed after being paused.
    // Always accompanied by subscription_updated.
    case 'subscription_unpaused': {
      const user = await resolveUser(payload);
      if (!user) throw new Error(`subscription_unpaused: user not found (sub_id=${subscriptionId})`);
      validateTransition(user.subscription_status || 'none', 'active');

      const tier = resolveTier(sub.variant_id);
      await db.query(
        `UPDATE users
         SET subscription_status = 'active',
             tier = $1,
             grace_until = NULL,
             ls_portal_url = $2,
             ls_update_payment_url = $3,
             updated_at = NOW()
         WHERE id = $4`,
        [tier, sub.urls?.customer_portal || null, sub.urls?.update_payment_method || null, user.id]
      );
      console.log(`[billing] subscription_unpaused: user=${user.id} tier=${tier}`);
      break;
    }

    // ── subscription_resumed ──────────────────────────────────────────────
    // Cancelled subscription resumed before grace period ended.
    // Always accompanied by subscription_updated.
    case 'subscription_resumed': {
      const user = await resolveUser(payload);
      if (!user) throw new Error(`subscription_resumed: user not found (sub_id=${subscriptionId})`);
      validateTransition(user.subscription_status || 'none', 'active');

      const tier = resolveTier(sub.variant_id);
      await db.query(
        `UPDATE users
         SET subscription_status = 'active',
             tier = $1,
             grace_until = NULL,
             current_period_ends_at = $2,
             ls_portal_url = $3,
             ls_update_payment_url = $4,
             updated_at = NOW()
         WHERE id = $5`,
        [
          tier,
          sub.renews_at || null,
          sub.urls?.customer_portal || null,
          sub.urls?.update_payment_method || null,
          user.id,
        ]
      );
      console.log(`[billing] subscription_resumed: user=${user.id} tier=${tier}`);
      break;
    }

    // ── order_created ─────────────────────────────────────────────────────
    // Initial purchase order. Always fires alongside subscription_created.
    // We log it. The subscription_created handler handles the DB update.
    case 'order_created': {
      const attrs = payload.data?.attributes;
      console.log(`[billing] order_created: order=${payload.data?.id} total=${attrs?.total_formatted || attrs?.total} user_id=${payload.meta?.custom_data?.user_id}`);
      break;
    }

    // ── order_refunded ────────────────────────────────────────────────────
    // Full or partial refund on an order. If the subscription was cancelled
    // as part of the refund, subscription_cancelled/expired events will follow.
    case 'order_refunded': {
      const attrs = payload.data?.attributes;
      console.log(`[billing] order_refunded: order=${payload.data?.id} refunded_amount=${attrs?.refunded_amount_formatted || attrs?.refunded_amount} user_id=${payload.meta?.custom_data?.user_id}`);
      break;
    }

    default:
      console.log(`[billing] Unhandled event type: ${eventName}`);
  }
}

// ---------------------------------------------------------------------------
// Invoice event handler
//
// These events send a Subscription Invoice object (NOT a Subscription object).
// Key differences:
//   - data.type = "subscription-invoices"
//   - data.attributes has: subscription_id, billing_reason, total, currency
//   - data.attributes does NOT have: variant_id, renews_at, ends_at, urls.customer_portal
//   - data.id = invoice ID (not subscription ID)
//
// We do NOT change subscription_status here. The accompanying subscription_updated
// event (which LS always fires alongside) handles all status transitions.
// This handler logs the payment event and updates the user's record with
// invoice metadata for display/debugging.
// ---------------------------------------------------------------------------
async function handleInvoiceEvent(eventName, payload) {
  const invoice = payload.data.attributes;
  const invoiceId = String(payload.data.id);
  const subscriptionId = String(invoice.subscription_id || '');

  const user = await resolveUser(payload);

  switch (eventName) {

    // ── subscription_payment_success ──────────────────────────────────────
    // Fires on: initial payment, every successful renewal, and alongside
    // subscription_payment_recovered.
    // billing_reason: "initial" | "renewal" | "updated"
    case 'subscription_payment_success': {
      if (!user) {
        throw new Error(`subscription_payment_success: user not found (sub_id=${subscriptionId})`);
      }
      console.log(`[billing] subscription_payment_success: user=${user.id} invoice=${invoiceId} reason=${invoice.billing_reason} total=${invoice.total_formatted || invoice.total} currency=${invoice.currency}`);
      break;
    }

    // ── subscription_payment_failed ───────────────────────────────────────
    // Fires when a renewal payment fails. LS retries up to 4 times over ~2 weeks.
    // The accompanying subscription_updated will set status to past_due.
    // Per LS docs: user keeps access during past_due (LS is retrying).
    //
    // Edge cases:
    //   - Card expired between cycles
    //   - Insufficient funds (temporary)
    //   - Bank declined (3DS challenge failed)
    //   - PayPal: retries every 5 days (different cadence)
    case 'subscription_payment_failed': {
      if (!user) {
        throw new Error(`subscription_payment_failed: user not found (sub_id=${subscriptionId})`);
      }
      // TODO: send payment-failed notification email to user with update_payment_method URL
      // The update_payment_method URL is stored on the user record from the last subscription event
      console.log(`[billing] subscription_payment_failed: user=${user.id} invoice=${invoiceId} total=${invoice.total_formatted || invoice.total}`);
      break;
    }

    // ── subscription_payment_recovered ────────────────────────────────────
    // Fires when a past_due subscription successfully collects payment.
    // Always accompanied by subscription_payment_success + subscription_updated.
    // The subscription_updated will set status back to active.
    case 'subscription_payment_recovered': {
      if (!user) {
        throw new Error(`subscription_payment_recovered: user not found (sub_id=${subscriptionId})`);
      }
      console.log(`[billing] subscription_payment_recovered: user=${user.id} invoice=${invoiceId} — payment retry succeeded`);
      break;
    }

    // ── subscription_payment_refunded ─────────────────────────────────────
    // Fires when a subscription invoice is refunded (full or partial).
    // If the refund causes a cancellation, subscription_cancelled/expired will follow.
    case 'subscription_payment_refunded': {
      if (!user) {
        throw new Error(`subscription_payment_refunded: user not found (sub_id=${subscriptionId})`);
      }
      console.log(`[billing] subscription_payment_refunded: user=${user.id} invoice=${invoiceId} refunded=${invoice.refunded_amount_formatted || invoice.refunded_amount}`);
      break;
    }

    default:
      console.log(`[billing] Unhandled invoice event: ${eventName}`);
  }
}

// ---------------------------------------------------------------------------
// Exported helpers for use in index.js (checkout URL creation, portal URL)
// ---------------------------------------------------------------------------
module.exports.VARIANT_ID_TO_TIER = VARIANT_ID_TO_TIER;
module.exports.TRIAL_GRANTS_TIER = TRIAL_GRANTS_TIER;
