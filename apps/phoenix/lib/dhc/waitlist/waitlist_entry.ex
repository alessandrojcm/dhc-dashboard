defmodule Dhc.Waitlist.WaitlistEntry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "waitlist" do
    field :email, :string
    field :status, :string
    field :initial_registration_date, :utc_datetime
    field :last_status_change, :utc_datetime
    field :last_contacted, :utc_datetime
    field :admin_notes, :string
    # Optimistic-concurrency version witness (ADR 0023); bumped on every
    # update via `Ecto.Changeset.optimistic_lock/3`, never client-writable.
    field :lock_version, :integer, default: 1
  end

  @doc false
  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:email, :status])
    |> validate_required([:email, :status])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_inclusion(
      :status,
      ~w(waiting invited paid deferred cancelled completed no_reply joined)
    )
    |> unique_constraint(:email)
  end

  @doc false
  def admin_update_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:status, :admin_notes, :last_status_change])
    |> validate_inclusion(
      :status,
      ~w(waiting invited paid deferred cancelled completed no_reply joined)
    )
  end
end
