-- Phase D.4a: Persistent audit event log
-- Append-only. Never UPDATE or DELETE rows from application code.

CREATE TABLE audit_events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    event_type VARCHAR(50) NOT NULL,
    ip_address INET,
    metadata   JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ae_user ON audit_events (user_id, created_at DESC);
CREATE INDEX idx_ae_type ON audit_events (event_type, created_at DESC);

-- Enforce append-only at the DB level — no application-code comment can be relied upon.
CREATE OR REPLACE FUNCTION prevent_audit_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only: % is not permitted', TG_OP;
END;
$$;

CREATE TRIGGER audit_events_no_update
  BEFORE UPDATE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();

CREATE TRIGGER audit_events_no_delete
  BEFORE DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();
