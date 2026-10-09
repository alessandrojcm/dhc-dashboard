defmodule Dhc.Waitlist.WaitlistEntry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Dhc.Waitlist.Standing

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "waitlist" do
    field :email, :string
    field :status, :string
    field :initial_registration_date, :utc_datetime
    field :last_status_change, :utc_datetime
    field :last_contacted, :utc_datetime
    field :removed_at, :utc_datetime
    field :admin_notes, :string
  end

  @doc false
  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:email])
    |> put_change(:status, "waiting")
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> unique_constraint(:email)
  end

  @doc false
  def admin_notes_changeset(entry, attrs) do
    cast(entry, attrs, [:admin_notes])
  end

  @doc false
  # Only `Dhc.Waitlist.change_standing/2` may build this changeset; it has
  # already checked the change against `Standing.allowed?/2`.
  def standing_changeset(entry, to, now) do
    entry
    |> change(status: to, last_status_change: now, removed_at: removed_at(to, now))
    |> validate_inclusion(:status, Standing.statuses())
    |> check_constraint(:removed_at, name: :waitlist_removed_at_matches_status)
  end

  defp removed_at("removed", now), do: now
  defp removed_at(_status, _now), do: nil
end
