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

  def package_digest(package) when is_map(package) do
    package
    |> normalize()
    |> Map.take(
      ~w(version capture_id guild_id tool_revision captured_at record_count digest users)
    )
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value(map, atom_key, string_key),
    do: Map.get(map, atom_key, Map.get(map, string_key))

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {normalize_key(key), normalize(nested_value)}
    end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
