defmodule Dhc.Repo.Migrations.Ale182SessionTokenHashing do
  @moduledoc """
  ALE-182: store session tokens as SHA-256 hashes, not plaintext.

  ## Why

  Pre-ALE-182, `Dhc.Auth.PrincipalToken.build_session_token/1` stored the raw
  opaque session cookie bytes verbatim in `principal_tokens.token`. A
  read-only DB leak could therefore mint a live session — the inverse of the
  magic-link and socket-token paths, which already stored only the digest. The
  auth code (`verify_session_token_query/1`, `delete_session_token/1`) was
  updated in the same release to hash the incoming cookie before lookup, so
  the application never reads the plaintext column.

  ## This migration

    1. **Backfill existing session rows in place** —
       `UPDATE principal_tokens SET token = digest(token, 'sha256') WHERE
       context = 'session'`. Only `session` rows are touched: `login`
       (magic-link) and `socket` rows already store the digest. Existing
       cookies keep working with zero user disruption, because the application
       hashes the incoming cookie before lookup and now matches the
       backfilled digest.
    2. **Add `CHECK (context IN ('login','session','socket'))`** — constrains
       the context column to the three known values. Added `NOT VALID` then
       `VALIDATE` so existing rows are checked without a long table lock.
    3. **Add `(principal_id, context)` composite index** — the hot lookup
       path (`delete_all_principal_sessions/1`, per-principal session
       enumeration) filters by both columns.
    4. **Add `created_at` index** — supports expiry cleanup scans that sweep
       rows older than the 30-day session window.
    5. **Drop the redundant standalone `(principal_id)` index** — superseded
       by the composite `(principal_id, context)` index, which satisfies every
       `principal_id`-leading query.

  The existing `UNIQUE (context, token)` index (from the auth foundation
  migration) already covers `(context, hashed_token)` lookups and is unchanged:
  the backfill writes one digest per row, so uniqueness is preserved.

  ## Deployment shape

  This migration is not compatible with overlapping old and new application
  versions. Deploy it under the drain/migrate/start procedure in
  `docs/ale-182-session-token-hashing-runbook.md`; old instances must be
  stopped before the release command runs and must not restart afterward.

  ## down/0

  **Backup-restore is the only rollback.** The backfill is a one-way hash: the
  plaintext session cookies cannot be recovered from their digests, so a
  `down/0` that "reversed" the backfill would invalidate every live session
  cookie and lock users out. The mechanical index drops and the CHECK drop
  are reversible in isolation, but the data change is not. Treat the whole
  migration as unsafe-after-write: restore from the pre-window backup to roll
  back (per the ALE-187 runbook's shared rollback policy).
  """

  use Ecto.Migration

  @context_check :principal_tokens_context_check
  @principal_context_index :principal_tokens_principal_id_context_index
  @created_at_index :principal_tokens_created_at_index
  @principal_index :principal_tokens_principal_id_index

  def up do
    # 1. Backfill existing session rows: hash the plaintext cookie in place.
    #    login (magic-link) and socket rows already store the digest.
    execute "UPDATE principal_tokens SET token = digest(token, 'sha256') WHERE context = 'session'"

    # 2. Constrain context to the three known values. NOT VALID then VALIDATE
    #    so existing rows are checked without a long table lock.
    execute "ALTER TABLE principal_tokens ADD CONSTRAINT #{@context_check} CHECK (context IN ('login','session','socket')) NOT VALID"
    execute "ALTER TABLE principal_tokens VALIDATE CONSTRAINT #{@context_check}"

    # 3. (principal_id, context) composite index — the hot per-principal
    #    session lookup path.
    create index(:principal_tokens, [:principal_id, :context], name: @principal_context_index)

    # 4. created_at index — expiry-cleanup scans.
    create index(:principal_tokens, [:created_at], name: @created_at_index)

    # 5. Drop the redundant standalone principal_id index, superseded by the
    #    composite. IF EXISTS guards a partial failure.
    execute "DROP INDEX IF EXISTS #{@principal_index}"
  end

  def down do
    # See @moduledoc: backup-restore is the only safe rollback. The backfill
    # is a one-way hash — the plaintext session cookies cannot be recovered
    # from their digests, so running a mechanical `down/0` against the
    # post-migration data would silently invalidate every live session cookie
    # and lock users out. Per the ALE-188 down/0 policy, ALE-182 is
    # unsafe-after-write: raise instead of performing a partial reversal that
    # would imply a rollback is safe. Restore from the pre-window backup to
    # roll back (ALE-187 runbook).
    raise ArgumentError,
          "ALE-182 session-token hashing is unsafe-after-write: the backfill " <>
            "is a one-way SHA-256 hash and cannot be reversed. Roll back via " <>
            "backup-restore per the ALE-187 runbook."
  end
end
