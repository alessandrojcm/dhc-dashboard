defmodule Dhc.Waitlist.Repository do
  @moduledoc """
  Repository module for Waitlist persistence.
  """

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @doc """
  Marks a waitlist entry as invited.
  """
  @spec mark_invited(String.t()) :: :ok
  def mark_invited(waitlist_id) when is_binary(waitlist_id) do
    from(w in WaitlistEntry, where: w.id == ^waitlist_id)
    |> Repo.update_all(
      set: [
        status: "invited",
        last_status_change: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    :ok
  end
end
