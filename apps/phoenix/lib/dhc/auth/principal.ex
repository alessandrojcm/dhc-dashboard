defmodule Dhc.Auth.Principal do
  @moduledoc """
  The DHC-owned login identity for exactly one Member (ADR 0009).

  A Principal owns the authoritative normalized login email and the login
  methods (magic link today, Discord External Identity in ALE-167). Pending
  Invitations do not have a Principal; Phoenix never creates a session for a
  Principal whose Member lacks current club access.

  ## Email normalization

  The canonical login email is stored as `citext` in Postgres and normalized
  to a stable lowercase + trimmed form at the changeset layer
  (`normalize_email/1`). A Discord-reported email is metadata only — it never
  overwrites this field (ALE-167).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @email_max_length 160

  schema "principals" do
    field :email, :string
    field :confirmed_at, :utc_datetime

    # Set by the auth context after a successful magic-link or (future)
    # Discord login. Virtual — not persisted. Used by the session-token
    # builder to stamp `authenticated_at` on the new session row.
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  @doc """
  Changeset for registering a new Principal or changing its email.

  Email is normalized (lowercase + trim) and validated for format, length, and
  uniqueness. Uniqueness is enforced at the DB level by a `citext` unique
  index; `unique_constraint/2` surfaces it as a changeset error.

  ## Options

    * `:validate_unique` - set to `false` to skip the unique check (useful for
      live-validation flows). Defaults to `true`.
  """
  def email_changeset(principal, attrs, opts \\ []) do
    principal
    |> cast(attrs, [:email])
    |> put_email_normalized()
    |> validate_email(opts)
  end

  @doc """
  Changeset that marks a Principal's email as confirmed by setting
  `confirmed_at` to now.
  """
  def confirm_changeset(principal) do
    change(principal, confirmed_at: DateTime.utc_now(:second))
  end

  defp put_email_normalized(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :email, normalize_email(email))
    end
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: @email_max_length)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Dhc.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  Normalizes an email to its canonical login form: trimmed and lowercased.

  This is the form stored in `principals.email` (also enforced as case-
  insensitive by the `citext` column). All Principal lookups by email go
  through this function.
  """
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def normalize_email(nil), do: nil
end
