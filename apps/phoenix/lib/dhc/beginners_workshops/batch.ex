defmodule Dhc.BeginnersWorkshops.Batch do
  @moduledoc """
  Ecto schema for `beginners_workshop_batches` (ALE-380): one automatic
  contact round of a Beginners' Workshop. Written only by the boundary's
  `send_due_batch` pass. `number` counts from 1 per workshop; `size` is the
  number of Intakes it created; the payment window ends at `window_ends_at`
  (23:59 Dublin time, or the Payment Cutoff when it reaches the cutoff date).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "beginners_workshop_batches" do
    field :workshop_id, :binary_id
    field :number, :integer
    field :size, :integer
    field :sent_at, :utc_datetime_usec
    field :window_ends_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:workshop_id, :number, :size, :sent_at, :window_ends_at])
    |> validate_required([:workshop_id, :number, :size, :sent_at, :window_ends_at])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_number(:size, greater_than_or_equal_to: 1)
  end

  @doc """
  ALE-394: a reschedule brings an open window's end forward to the new
  Payment Cutoff (never later).
  """
  @spec clamp_window_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def clamp_window_changeset(%__MODULE__{} = batch, %DateTime{} = cutoff),
    do: change(batch, window_ends_at: cutoff)
end
