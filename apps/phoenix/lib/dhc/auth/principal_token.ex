defmodule Dhc.Auth.PrincipalToken do
  @moduledoc """
  Token store for the Phoenix auth foundation.

  A `principal_tokens` row carries one of two contexts:

    * `"login"` — a magic-link token. Random bytes are sent to the Principal's
      email; the SHA-256 hash is stored. Single-use, expires after 15 minutes.
    * `"session"` — an opaque DB-backed session token. Random bytes are stored
      hashed; the original is placed in the cookie. Expires after 30 days
      (absolute — no sliding refresh).

  Both tokens are looked up by `(context, hashed_token)`. Storing only the
  hash means a read-only DB leak cannot reconstruct a usable token.

  Shape follows `mix phx.gen.auth`'s `UserToken`, adapted to DHC's 30-day
  session policy and `principals` naming. The generator's 14-day session and
  7-day email-change contexts are not used here.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Dhc.Auth.PrincipalToken

  @hash_algorithm :sha256
  @rand_size 32

  # Magic-link expiry — must stay short (someone with mailbox access can use
  # it). The spec (docs/auth-migration-specification.md) fixes this at 15 min.
  @magic_link_validity_in_minutes 15

  # Absolute session lifetime. The spec fixes this at 30 days, no sliding
  # refresh. Login rotates the session (deletes outstanding sessions for the
  # principal only on explicit sign-out-everywhere; per-device logout deletes
  # one). See `Dhc.Auth` for the rotation/revocation policy.
  @session_validity_in_days 30

  # Short-lived socket token (ALE-164). Long enough for a browser to fetch it
  # and open a WebSocket immediately; short enough that a leaked token is not
  # useful. Single-use is not required (the socket lifetime is the real
  # boundary), but we store only the hash so a read-only DB leak cannot
  # reconstruct a usable token.
  @socket_validity_in_seconds 60

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "principal_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :principal, Dhc.Auth.Principal

    timestamps(type: :utc_datetime, updated_at: false, inserted_at: :created_at)
  end

  @doc """
  Builds a random opaque session token and its DB row.

  The raw token is returned to the caller (to be placed in a signed cookie);
  the row stores only the SHA-256 hash. `principal.authenticated_at` (set by
  the auth context on login) stamps the row's `authenticated_at`.
  """
  def build_session_token(principal) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = principal.authenticated_at || DateTime.utc_now(:second)

    {token,
     %PrincipalToken{
       token: token,
       context: "session",
       principal_id: principal.id,
       authenticated_at: dt
     }}
  end

  @doc """
  Builds a short-lived socket token and its DB row (ALE-164).

  The raw token (32 random bytes) is returned to the caller to be Base64-
  encoded for transport as the `authToken` subprotocol value; the row stores
  only the SHA-256 hash. Expiry is enforced by `verify_socket_token_query/1`
  via `@socket_validity_in_seconds`.
  """
  def build_socket_token(principal) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)
    dt = principal.authenticated_at || DateTime.utc_now(:second)

    {token,
     %PrincipalToken{
       token: hashed_token,
       context: "socket",
       principal_id: principal.id,
       authenticated_at: dt
     }}
  end

  @doc """
  Query that verifies a session token and returns `{principal, token_row}`.

  Valid iff the (context, hashed_token) row exists, has not expired
  (inserted_at within `@session_validity_in_days`), and the principal still
  exists.
  """
  def verify_session_token_query(token) do
    query =
      from t in by_token_and_context_query(token, "session"),
        join: p in assoc(t, :principal),
        where: t.created_at > ago(@session_validity_in_days, "day"),
        select: {%{p | authenticated_at: t.authenticated_at}, t}

    {:ok, query}
  end

  @doc """
  Query that verifies a short-lived socket token and returns `{principal,
  token_row}` (ALE-164).

  `token` is the raw bytes the browser received Base64-encoded from
  `GET /api/auth/socket-token`. Valid iff the (context="socket", hashed_token)
  row exists, was created within `@socket_validity_in_seconds`, and the
  principal still exists.
  """
  def verify_socket_token_query(token) when is_binary(token) do
    hashed_token = :crypto.hash(@hash_algorithm, token)

    query =
      from t in by_token_and_context_query(hashed_token, "socket"),
        join: p in assoc(t, :principal),
        where: t.created_at > ago(^@socket_validity_in_seconds, "second"),
        select: {p, t}

    {:ok, query}
  end

  @doc """
  Builds a magic-link token: returns the URL-safe encoded token (to email) and
  the DB row (stores the hash). `sent_to` is the email the link was sent to;
  it must match the Principal's current email at verification time, so a
  login link sent to an old email becomes invalid after an email change.
  """
  def build_magic_link_token(principal) do
    build_hashed_token(principal, "login", principal.email)
  end

  defp build_hashed_token(principal, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %PrincipalToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       principal_id: principal.id
     }}
  end

  @doc """
  Query that verifies a magic-link token and returns `{principal, token_row}`
  or `nil`.

  Valid iff the encoded token decodes, the (context="login", hashed_token) row
  exists, the row was created within `@magic_link_validity_in_minutes`, and
  `sent_to` matches the Principal's current email (so a link sent to an old
  email cannot be used after an email change).
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from t in by_token_and_context_query(hashed_token, "login"),
            join: p in assoc(t, :principal),
            where: t.created_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: t.sent_to == p.email,
            select: {p, t}

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from PrincipalToken, where: [token: ^token, context: ^context]
  end
end
