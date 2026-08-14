defmodule Dhc.Discord.RosterCapture do
  @moduledoc """
  One-shot Discord guild roster capture with no dashboard roster persistence.

  The caller supplies the task-local bot credential; this module never reads or
  accepts interactive OAuth credentials and returns only support-safe receipts.
  """

  alias Dhc.Discord.{RosterClient, RosterDigest, RosterPackage, RosterReceipts}

  @type safe_result :: %{
          preflight_receipt_id: Ecto.UUID.t(),
          capture_id: Ecto.UUID.t(),
          package_path: Path.t(),
          digest: String.t(),
          count: non_neg_integer(),
          reconciliation: String.t()
        }

  def capture(options) do
    with :ok <- validate_options(options),
         {:ok, preflight} <- preflight(options),
         {:ok, users} <- fetch_all(options, nil, MapSet.new(), []),
         {:ok, result} <- write_capture(options, preflight, users) do
      {:ok, result}
    end
  end

  def cleanup(package_path), do: RosterPackage.delete(package_path)

  defp preflight(options) do
    result =
      with {:ok, %{status: status, body: %{"id" => application_id}}} when status in 200..299 <-
             client(options).application(options.token),
           :ok <- expect_application(application_id, options.bot_application_id),
           {:ok, %{status: status, body: members}} when status in 200..299 <-
             client(options).members(options.token, options.guild_id, nil),
           :ok <- validate_page(members) do
        evidence_digest =
          digest(%{
            application_id: application_id,
            guild_id: options.guild_id,
            endpoint: "guild_members",
            status: 200
          })

        receipt(options).create(%{
          kind: :preflight,
          status: :succeeded,
          actor_id: options.actor_id,
          guild_id: options.guild_id,
          bot_application_id: application_id,
          tool_revision: options.tool_revision,
          evidence_digest: evidence_digest,
          record_count: length(members),
          result: "guild-members endpoint available"
        })
      else
        {:ok, %{status: status}} -> {:error, {:preflight_failed, status}}
        {:ok, _} -> {:error, :malformed_preflight_response}
        {:error, _} = error -> error
        :error -> {:error, :unexpected_bot_application}
      end

    case result do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, reason} = error ->
        _ =
          receipt(options).create(%{
            kind: :preflight,
            status: :failed,
            actor_id: options.actor_id,
            guild_id: options.guild_id,
            bot_application_id: options.bot_application_id,
            tool_revision: options.tool_revision,
            evidence_digest: digest(%{guild_id: options.guild_id, result: "failed"}),
            result: support_safe_reason(reason)
          })

        error
    end
  end

  defp fetch_all(options, cursor, seen, acc) do
    case client(options).members(options.token, options.guild_id, cursor) do
      {:ok, %{status: 429, body: body}} ->
        with {:ok, retry_after} <- retry_after(body),
             :ok <- sleeper(options).sleep(retry_after) do
          fetch_all(options, cursor, seen, acc)
        end

      {:ok, %{status: status, body: page, headers: headers}} when status in 200..299 ->
        with :ok <- validate_page(page),
             {:ok, users} <- recognition_users(page),
             :ok <- reject_duplicates(users, seen),
             :ok <- cursor_progresses?(cursor, users),
             :ok <- wait_for_rate_limit(headers, options) do
          seen = Enum.reduce(users, seen, &MapSet.put(&2, &1.id))
          acc = acc ++ users

          case List.last(users) do
            nil -> {:ok, acc}
            %{id: cursor} -> fetch_all(options, cursor, seen, acc)
          end
        end

      {:ok, %{status: status}} ->
        {:error, {:guild_members_failed, status}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :malformed_guild_members_response}
    end
  end

  defp write_capture(options, preflight, users) do
    roster_digest = RosterDigest.digest(users)
    capture_id = Ecto.UUID.generate()

    package = %{
      version: 1,
      capture_id: capture_id,
      guild_id: options.guild_id,
      tool_revision: options.tool_revision,
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      record_count: length(users),
      digest: roster_digest,
      users: users
    }

    with {:ok, package_path} <-
           RosterPackage.write(options.package_dir, capture_id, package, options.package_key) do
      case receipt(options).create(%{
             id: capture_id,
             kind: :capture,
             status: :succeeded,
             actor_id: options.actor_id,
             guild_id: options.guild_id,
             bot_application_id: options.bot_application_id,
             tool_revision: options.tool_revision,
             evidence_digest:
               digest(%{preflight_receipt_id: preflight.id, guild_id: options.guild_id}),
             package_digest: roster_digest,
             record_count: length(users),
             result: "capture complete; no staged assignments created",
             preflight_receipt_id: preflight.id
           }) do
        {:ok, capture} ->
          {:ok,
           %{
             preflight_receipt_id: preflight.id,
             capture_id: capture.id,
             package_path: package_path,
             digest: roster_digest,
             count: length(users),
             reconciliation:
               "captured #{length(users)} roster entries; staged assignments created: 0"
           }}

        {:error, reason} ->
          _ = RosterPackage.delete(package_path)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_options(options) do
    required = [
      :token,
      :guild_id,
      :bot_application_id,
      :actor_id,
      :tool_revision,
      :package_dir,
      :package_key
    ]

    if Enum.all?(required, &(is_binary(Map.get(options, &1)) and Map.get(options, &1) != "")) do
      :ok
    else
      {:error, :missing_task_local_configuration}
    end
  end

  defp expect_application(expected, expected), do: :ok
  defp expect_application(_, _), do: :error

  defp validate_page(page) when is_list(page), do: :ok
  defp validate_page(_), do: {:error, :malformed_member_page}

  defp recognition_users(page) do
    Enum.reduce_while(page, {:ok, []}, fn
      %{"user" => %{"id" => id, "username" => username} = user} = member, {:ok, users}
      when is_binary(id) and id != "" and is_binary(username) and username != "" ->
        user = %{
          id: id,
          username: username,
          global_name: Map.get(user, "global_name"),
          nickname: Map.get(member, "nick")
        }

        {:cont, {:ok, users ++ [user]}}

      _, _ ->
        {:halt, {:error, :malformed_roster_user}}
    end)
  end

  defp reject_duplicates(users, seen) do
    ids = Enum.map(users, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)) and
         Enum.all?(ids, &(not MapSet.member?(seen, &1))),
       do: :ok,
       else: {:error, :duplicate_roster_user}
  end

  defp cursor_progresses?(_cursor, []), do: :ok
  defp cursor_progresses?(cursor, [%{id: cursor} | _]), do: {:error, :cursor_non_progress}
  defp cursor_progresses?(_, _), do: :ok

  defp retry_after(%{"retry_after" => seconds}) when is_number(seconds) and seconds >= 0,
    do: {:ok, trunc(seconds * 1_000)}

  defp retry_after(_), do: {:error, :malformed_rate_limit_response}

  defp wait_for_rate_limit(headers, options) do
    remaining = header(headers, "x-ratelimit-remaining")
    reset_after = header(headers, "x-ratelimit-reset-after")

    if remaining == "0" and is_binary(reset_after) do
      case Float.parse(reset_after) do
        {seconds, ""} when seconds >= 0 -> sleeper(options).sleep(trunc(seconds * 1_000))
        _ -> {:error, :malformed_rate_limit_headers}
      end
    else
      :ok
    end
  end

  defp header(headers, name),
    do:
      headers
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(key) == name, do: List.first(List.wrap(value))
      end)

  defp support_safe_reason({:preflight_failed, status}),
    do: "preflight endpoint unavailable (HTTP #{status})"

  defp support_safe_reason(:unexpected_bot_application),
    do: "bot application identity did not match"

  defp support_safe_reason(_), do: "preflight verification failed"
  defp digest(term), do: :crypto.hash(:sha256, Jason.encode!(term)) |> Base.encode16(case: :lower)
  defp client(options), do: Map.get(options, :client, RosterClient)
  defp receipt(options), do: Map.get(options, :receipt_store, RosterReceipts)
  defp sleeper(options), do: Map.get(options, :sleeper, Dhc.Discord.RosterCapture.Sleeper)
end
