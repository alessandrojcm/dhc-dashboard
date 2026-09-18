defmodule Dhc.Inventory.Locks do
  @moduledoc """
  Locked primary-key reads for inventory mutations.

  `Ecto.Repo.get/3` does not accept `:lock`; unknown options are ignored, so
  passing a lock clause as a Repo option is a plain unlocked SELECT.
  Callers that need a row lock must go through this helper.
  """

  import Ecto.Query

  alias Dhc.Repo

  @spec get_for_update(module(), term()) :: struct() | nil
  def get_for_update(schema, id) do
    schema
    |> for_update_query(id)
    |> Repo.one()
  end

  @spec for_update_query(module(), term()) :: Ecto.Query.t()
  def for_update_query(schema, id) do
    from(s in schema, where: s.id == ^id, lock: "FOR UPDATE")
  end
end
