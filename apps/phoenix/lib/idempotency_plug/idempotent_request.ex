defmodule IdempotencyPlug.IdempotentRequest do
  @moduledoc """
  Request-store schema vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "idempotency_plug_requests" do
    field :fingerprint, :string
    field :data, IdempotencyPlug.ErlangTerm
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(request), do: change(request) |> unique_constraint(:id)
end
