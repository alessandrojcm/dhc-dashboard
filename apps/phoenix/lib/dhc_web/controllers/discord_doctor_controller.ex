defmodule DhcWeb.DiscordDoctorController do
  use DhcWeb, :controller

  alias Dhc.Discord

  def report(conn, params) do
    case Discord.doctor_report(refresh: params["refresh"] == "true") do
      {:ok, report} ->
        render(conn, :report, report: report)

      {:error, _reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: %{detail: "Discord member list unavailable"}})
    end
  end

  def kick(conn, params) do
    case validate_kick_request(params) do
      {:ok, user_ids, note} ->
        execute_kick(conn, user_ids, note)

      {:error, detail} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{detail: detail}})
    end
  end

  defp execute_kick(conn, user_ids, note) do
    principal = conn.assigns.current_session.principal

    case Discord.doctor_kick(user_ids, principal.id, note) do
      {:ok, results} ->
        render(conn, :kick, results: results)

      {:error, :admin_not_found} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{detail: "Authenticated administrator profile unavailable"}})

      {:error, _reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: %{detail: "Discord member list unavailable"}})
    end
  end

  defp validate_kick_request(params) do
    with :ok <- validate_kick_fields(params),
         {:ok, user_ids} <- validate_kick_user_ids(params["discordUserIds"]),
         :ok <- validate_kick_note(params) do
      {:ok, user_ids, params["note"]}
    end
  end

  defp validate_kick_fields(params) do
    if Enum.all?(Map.keys(params), &(&1 in ["discordUserIds", "note"])) do
      :ok
    else
      {:error, "Request contains unsupported fields"}
    end
  end

  defp validate_kick_user_ids(user_ids) when not is_list(user_ids) or user_ids == [],
    do: {:error, "At least one Discord user id is required"}

  defp validate_kick_user_ids(user_ids) do
    cond do
      not Enum.all?(user_ids, &(is_binary(&1) and &1 != "")) ->
        {:error, "Discord user ids must be non-empty strings"}

      length(user_ids) != length(Enum.uniq(user_ids)) ->
        {:error, "Discord user ids must be unique"}

      true ->
        {:ok, user_ids}
    end
  end

  defp validate_kick_note(params) do
    if Map.has_key?(params, "note") and not is_binary(params["note"]) do
      {:error, "Note must be a string"}
    else
      :ok
    end
  end
end
