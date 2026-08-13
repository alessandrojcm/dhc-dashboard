defmodule Dhc.Discord.RosterReceipts do
  @moduledoc false

  alias Dhc.Discord.RosterReceipt
  alias Dhc.Repo

  def create(attrs), do: Repo.insert(RosterReceipt.changeset(%RosterReceipt{}, attrs))
end
