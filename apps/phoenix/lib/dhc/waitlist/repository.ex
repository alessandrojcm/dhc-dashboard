defmodule Dhc.Waitlist.Repository do
  @moduledoc """
  Repository module for Waitlist persistence.
  """

  alias Dhc.Waitlist

  @doc """
  Moves an `attended` Waitlist entry to `invited` through the Waitlist
  standing function, inside the caller's Invitation transaction. Any other
  standing is refused, so a waiting person cannot be invited directly.
  """
  @spec mark_invited(String.t()) ::
          :ok | {:error, {:waitlist_standing, atom() | Ecto.Changeset.t()}}
  def mark_invited(waitlist_id) when is_binary(waitlist_id) do
    case Waitlist.change_standing(waitlist_id, "invited") do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, {:waitlist_standing, reason}}
    end
  end
end
