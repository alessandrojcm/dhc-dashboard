defmodule Dhc.Discord.RosterDigest do
  @moduledoc false

  def digest(users) when is_list(users) do
    users
    |> Enum.map(fn user ->
      [
        value(user, :id, "id"),
        value(user, :username, "username"),
        value(user, :global_name, "global_name"),
        value(user, :nickname, "nickname")
      ]
    end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value(map, atom_key, string_key),
    do: Map.get(map, atom_key, Map.get(map, string_key))
end
