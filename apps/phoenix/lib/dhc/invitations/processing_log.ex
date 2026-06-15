defmodule Dhc.Invitations.ProcessingLog do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "invitation_processing_logs" do
    field :user_id, Ecto.UUID
    field :total_count, :integer
    field :success_count, :integer
    field :failure_count, :integer
    field :results, :map
    field :created_at, :utc_datetime
  end
end
