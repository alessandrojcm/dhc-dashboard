defmodule Dhc.Waitlist.Repository do
  @moduledoc """
  Repository module for Waitlist persistence.
  """

  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @doc """
  Marks a waitlist entry as invited.
  """
  @spec mark_invited(String.t()) :: :ok | {:error, :not_found}
  def mark_invited(waitlist_id) when is_binary(waitlist_id) do
    case Repo.get(WaitlistEntry, waitlist_id) do
      nil ->
        {:error, :not_found}

      %WaitlistEntry{} = entry ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        entry
        |> Ecto.Changeset.change(status: "invited", last_status_change: now)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
        |> then(fn {:ok, _entry} -> :ok end)
    end
  end
end
