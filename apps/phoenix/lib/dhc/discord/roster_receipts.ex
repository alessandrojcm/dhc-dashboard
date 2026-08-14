defmodule Dhc.Discord.RosterReceipts do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Discord.RosterReceipt
  alias Dhc.Repo

  def create(attrs) do
    {programmatic, attrs} =
      Map.split(attrs, [:id, :execution_id, :actor_id, :preflight_receipt_id])

    RosterReceipt
    |> struct(programmatic)
    |> RosterReceipt.changeset(attrs)
    |> Repo.insert()
  end

  def capture_exists?(capture_id) do
    Repo.exists?(
      from receipt in RosterReceipt,
        where: receipt.id == ^capture_id and receipt.kind == :capture
    )
  end
end
