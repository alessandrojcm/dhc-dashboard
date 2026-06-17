defmodule Dhc.Waitlist do
  @moduledoc """
  Waitlist context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Repo

  @waitlist_open_key "waitlist_open"

  @doc """
  Returns the public waitlist status.

  Missing or malformed settings are treated as closed so the public endpoint
  always returns a safe domain-shaped status instead of exposing settings rows.
  """
  @spec status() :: %{is_open: boolean()}
  def status do
    %{is_open: open?()}
  end

  @spec open?() :: boolean()
  def open? do
    from(s in "settings",
      where: field(s, :key) == ^@waitlist_open_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> case do
      "true" -> true
      _ -> false
    end
  end
end
