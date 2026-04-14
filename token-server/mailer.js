// ============================================================================
// mailer.js — Transactional Email (Phase D)
//
// Uses nodemailer with SMTP. Works with any provider:
//   - Resend SMTP (smtp.resend.com, port 465, user "resend")
//   - SendGrid (smtp.sendgrid.net, port 587, user "apikey")
//   - Postmark (smtp.postmarkapp.com, port 587)
//   - Any standard SMTP server
//
// Exports:
//   sendPasswordResetEmail(toEmail, rawToken)
//   sendVerificationEmail(toEmail, rawToken)
//   sendSecurityAlertEmail(toEmail, eventType, details)
//   sendPaymentFailedEmail(toEmail, updatePaymentUrl)
// ============================================================================

const nodemailer = require('nodemailer');

// ---------------------------------------------------------------------------
// Transport configuration — reads from .env
// ---------------------------------------------------------------------------
const transporter = nodemailer.createTransport({
  host:   process.env.SMTP_HOST,
  port:   parseInt(process.env.SMTP_PORT || '587', 10),
  secure: process.env.SMTP_PORT === '465', // true for 465 (TLS), false for 587 (STARTTLS)
  auth: {
    user: process.env.SMTP_USER,
    pass: process.env.SMTP_PASS,
  },
});

// Validate SMTP transport at startup via transporter.verify() and log any
// verification errors without exiting, so email failures don't block the server.
// Only runs when SMTP_HOST is set — skipped in dev environments without SMTP.
if (process.env.SMTP_HOST) {
  transporter.verify().then(() => {
    console.log('[mailer] SMTP transport verified');
  }).catch(err => {
    console.error('[mailer] SMTP transport verification failed:', err.message);
    // Do not process.exit() — email failure must not block the whole server
  });
}

const FROM = process.env.SMTP_FROM || 'Inter <noreply@inter.app>';

// Base URL for links in emails — resolves to production domain or localhost.
// Use BILLING_PAGE_BASE_URL if set (same domain as the server), fallback to localhost.
function baseUrl() {
  return process.env.BILLING_PAGE_BASE_URL || `http://localhost:${process.env.PORT || 3000}`;
}

// ---------------------------------------------------------------------------
// sendPasswordResetEmail
// Called from: POST /auth/forgot-password (fire-and-forget)
// ---------------------------------------------------------------------------
async function sendPasswordResetEmail(toEmail, rawToken) {
  const resetUrl = `${baseUrl()}/reset-password?token=${encodeURIComponent(rawToken)}`;

  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Reset your Inter password',
    text: [
      'You requested a password reset for your Inter account.',
      '',
      'Click the link below to set a new password. The link expires in 1 hour.',
      '',
      resetUrl,
      '',
      'If you did not request this, you can safely ignore this email.',
      'Your password will not change until you click the link above.',
    ].join('\n'),
    html: `
      <p>You requested a password reset for your Inter account.</p>
      <p>Click the button below to set a new password.
         <strong>The link expires in 1 hour.</strong></p>
      <p style="margin:24px 0">
        <a href="${resetUrl}" style="background:#007AFF;color:#fff;padding:12px 24px;
           border-radius:6px;text-decoration:none;font-weight:bold">
          Reset password
        </a>
      </p>
      <p><small>Or copy this URL: ${resetUrl}</small></p>
      <p style="color:#888;font-size:12px">
        If you did not request this, you can safely ignore this email.
      </p>
    `,
  });
}

// ---------------------------------------------------------------------------
// sendVerificationEmail
// Called from: register() flow (fire-and-forget)
// ---------------------------------------------------------------------------
async function sendVerificationEmail(toEmail, rawToken) {
  const verifyUrl = `${baseUrl()}/auth/verify-email?token=${encodeURIComponent(rawToken)}`;

  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Verify your Inter email address',
    text: [
      'Welcome to Inter! Please verify your email address.',
      '',
      verifyUrl,
      '',
      'This link expires in 8 hours.',
    ].join('\n'),
    html: `
      <p>Welcome to Inter! Please verify your email address.</p>
      <p style="margin:24px 0">
        <a href="${verifyUrl}" style="background:#007AFF;color:#fff;padding:12px 24px;
           border-radius:6px;text-decoration:none;font-weight:bold">
          Verify email
        </a>
      </p>
      <p><small>This link expires in 8 hours.</small></p>
    `,
  });
}

// ---------------------------------------------------------------------------
// sendSecurityAlertEmail
// Called from: refresh token theft detection (fire-and-forget)
// ---------------------------------------------------------------------------

// Escape HTML special characters to prevent XSS when interpolating
// any string (including user-controlled values) into an HTML email body.
function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function sendSecurityAlertEmail(toEmail, eventType, details) {
  const safeEventType = escHtml(eventType);

  // Render details as escaped key: value lines for the HTML body
  const safeDetails = details && typeof details === 'object'
    ? Object.entries(details)
        .map(([k, v]) => `<br><small>${escHtml(k)}: ${escHtml(String(v))}</small>`)
        .join('')
    : '';

  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Security alert — Inter account',
    text: [
      `A security event was detected on your Inter account: ${eventType}`,
      '',
      'If this was not you, please change your password immediately.',
      '',
      JSON.stringify(details, null, 2),
    ].join('\n'),
    html: `
      <p><strong>Security alert:</strong> ${safeEventType}</p>
      <p>A security event was detected on your Inter account.
         If this was not you, please change your password immediately.</p>
      <p style="color:#888;font-size:12px">
        Event details: ${escHtml(new Date().toISOString())}${safeDetails}
      </p>
    `,
  });
}

// ---------------------------------------------------------------------------
// sendPaymentFailedEmail
// Called from: billing.js subscription_payment_failed handler
// ---------------------------------------------------------------------------
async function sendPaymentFailedEmail(toEmail, updatePaymentUrl) {
  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Action required: update your Inter payment method',
    text: [
      'Your most recent subscription payment failed.',
      'Please update your payment method to keep your subscription active.',
      '',
      updatePaymentUrl || 'Please log in to manage your subscription.',
    ].join('\n'),
    html: `
      <p>Your most recent subscription payment failed.</p>
      <p>Please update your payment method to keep your subscription active.</p>
      ${updatePaymentUrl ? `
      <p style="margin:24px 0">
        <a href="${escHtml(updatePaymentUrl)}" style="background:#FF3B30;color:#fff;padding:12px 24px;
           border-radius:6px;text-decoration:none;font-weight:bold">
          Update payment method
        </a>
      </p>` : ''}
    `,
  });
}

module.exports = {
  sendPasswordResetEmail,
  sendVerificationEmail,
  sendSecurityAlertEmail,
  sendPaymentFailedEmail,
};
