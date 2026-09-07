defmodule Dhc.Inventory.Loan do
  @moduledoc """
  Ecto schema for `inventory_loans` (ALE-282 expand).

  Retained loan fact. `item_slug_snapshot` and `item_label_snapshot` are
  immutable borrower-history display facts captured at request time;
  `approved_container_path_snapshot` is captured at approval for the entitled
  collection flow. Snapshots are presentation evidence, not a second item
  identity or availability source. Storage only — lifecycle commands land in
  ALE-286. Not reachable through `Dhc.Inventory` yet.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "inventory_loans" do
    field :item_id, :binary_id
    field :borrower_principal_id, :binary_id
    field :status, :string
    field :requested_start_on, :date
    field :requested_due_on, :date
    field :approved_start_on, :date
    field :approved_due_on, :date
    field :checked_out_at, :utc_datetime_usec
    field :returned_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :decided_by_principal_id, :binary_id
    field :returned_by_principal_id, :binary_id
    field :request_note, :string
    field :decision_note, :string
    field :item_slug_snapshot, :string
    field :item_label_snapshot, :string
    field :approved_container_path_snapshot, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
