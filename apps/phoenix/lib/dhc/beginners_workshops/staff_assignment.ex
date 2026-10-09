defmodule Dhc.BeginnersWorkshops.StaffAssignment do
  @moduledoc """
  Ecto schema for `beginners_workshop_staff`: one Principal on a Beginners'
  Workshop's Staff, as its `coach` (at most one) or an `assistant`.

  Written only by `Dhc.BeginnersWorkshops.Commands` under the Beginners'
  Workshop lock, and never updated: a change of role deletes the row and
  inserts a new one, so a row id names exactly one assignment. Who may be
  assigned (a coach must hold `beginners.workshops.lead` at assignment) is
  the boundary's rule, not this schema's.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type role :: :coach | :assistant
  @type t :: %__MODULE__{}

  @roles ~w(coach assistant)

  schema "beginners_workshop_staff" do
    field :workshop_id, :binary_id
    field :principal_id, :binary_id
    field :role, :string
    field :assigned_by_principal_id, :binary_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @doc "Every Staff role."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "A new assignment."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:workshop_id, :principal_id, :role, :assigned_by_principal_id])
    |> validate_required([:workshop_id, :principal_id, :role])
    |> validate_inclusion(:role, @roles)
  end
end
