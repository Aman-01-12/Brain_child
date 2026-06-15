-- ============================================================================
-- Migration 019: User preferences (profile settings)
--
-- Adds user-editable profile preferences consumed by the unified Settings
-- window:
--   • timezone — IANA identifier (e.g. 'Asia/Kolkata'). NULL = system default.
--     When set, scheduling uses it as the default host timezone.
--   • language — BCP-47-ish tag (e.g. 'en-US'). NULL = system default.
--     Stored now so future clients inherit it; the macOS app ships it as a
--     "coming soon" display until localization lands.
-- ============================================================================

ALTER TABLE users ADD COLUMN IF NOT EXISTS timezone TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS language TEXT;
