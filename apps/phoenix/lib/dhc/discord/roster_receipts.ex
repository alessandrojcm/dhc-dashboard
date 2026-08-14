defmodule Dhc.Discord.RosterReceipts do
  @moduledoc false

  alias Dhc.Discord.RosterReceipt
  alias Dhc.Repo

  def create(attrs) do
    {id, attrs} = Map.pop(attrs, :id)
    Repo.insert(RosterReceipt.changeset(%RosterReceipt{id: id}, attrs))
  end
end
