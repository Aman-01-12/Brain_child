-- Migration 005: Rename refresh_tokens.replaced_by → predecessor_id
--
-- "replaced_by" implied the value pointed to a *newer* token that superseded
-- this one. The actual semantics are the opposite: the *new* token stores the
-- ID of the *old* token it rotated from. "predecessor_id" is unambiguous.
--
-- Safe on a live table — RENAME COLUMN acquires an ACCESS EXCLUSIVE lock only
-- briefly (metadata change only, no row rewrite).

ALTER TABLE refresh_tokens
    RENAME COLUMN replaced_by TO predecessor_id;
