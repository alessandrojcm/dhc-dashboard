defmodule Dhc.Discord.RosterCapture do
  @moduledoc """
  One-shot Discord guild roster capture with no dashboard roster persistence.

  The caller supplies the task-local bot credential; this module never reads or
  accepts interactive OAuth credentials and returns only support-safe receipts.
  """

  alias Dhc.Discord.{
    RosterClient,
    RosterDigest,
    RosterExecutions,
    RosterPackage,
    RosterReceipts
  }

  @page_limit 1_000

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
         {:ok, execution} <- execution_store(options).claim(options.execution_id, options) do
      options =
        options
        |> Map.put(:actor_id, execution.actor_id)
        |> Map.put(:execution_id, execution.id)

      result = do_capture(options)
      outcome = if match?({:ok, _}, result), do: :succeeded, else: :failed

      case execution_store(options).complete(execution, outcome) do
        {:ok, _execution} -> result
        {:error, reason} -> {:error, {:execution_completion_failed, reason}}
      end
    end
  end

  def cleanup(package_path), do: RosterPackage.delete(package_path)

  defp do_capture(options) do
    receipt_store = receipt(options)

    with :ok <-
           RosterPackage.reconcile_orphans(
             options.package_dir,
             fn capture_id -> receipt_store.capture_exists?(capture_id) end
           ),
         {:ok, preflight} <- preflight(options),
         {:ok, users} <- fetch_all(options, nil, MapSet.new(), []),
         {:ok, result} <- write_capture(options, preflight, users) do
      {:ok, result}
    end
  end

  defp preflight(options) do
    case verify_preflight(options) do
      {:ok, evidence} ->
        create_preflight_receipt(
          options,
          :succeeded,
          evidence,
          "guild-members endpoint available"
        )

      {:error, reason, evidence} ->
        case create_preflight_receipt(
               options,
               :failed,
               evidence,
               support_safe_reason(reason)
             ) do
          {:ok, _receipt} ->
            {:error, reason}

          {:error, receipt_reason} ->
            {:error, {:preflight_receipt_persistence_failed, reason, receipt_reason}}
        end
    end
  end

  defp verify_preflight(options) do
    base_evidence = %{
      expected_application_id: options.bot_application_id,
      guild_id: options.guild_id,
      application_endpoint: "oauth2_applications_me",
      members_endpoint: "guild_members"
    }

    case client(options).application(options.token, request_options(options)) do
      {:ok, %{status: status, body: %{"id" => application_id}}}
      when status in 200..299 and is_binary(application_id) and application_id != "" ->
        evidence =
          Map.merge(base_evidence, %{
            application_status: status,
            observed_application_id: application_id
          })

        if application_id == options.bot_application_id do
          verify_preflight_member(options, evidence)
        else
          {:error, :unexpected_bot_application, Map.put(evidence, :result, "identity_mismatch")}
        end

      {:ok, %{status: status}} ->
        {:error, {:preflight_failed, :application, status},
         Map.merge(base_evidence, %{application_status: status, result: "application_unavailable"})}

      {:error, _reason} ->
        {:error, {:preflight_transport, :application},
         Map.put(base_evidence, :result, "application_transport_failure")}

      _other ->
        {:error, :malformed_preflight_response,
         Map.put(base_evidence, :result, "malformed_application_response")}
    end
  end

  defp verify_preflight_member(options, evidence) do
    case client(options).members(
           options.token,
           options.guild_id,
           nil,
           1,
           request_options(options)
         ) do
      {:ok, %{status: status, body: members, headers: headers}} when status in 200..299 ->
        with {:ok, count} <- validate_preflight_page(members),
             :ok <- wait_for_rate_limit(headers, options) do
          {:ok,
           Map.merge(evidence, %{
             members_status: status,
             sampled_count: count,
             result: "succeeded"
           })}
        else
          {:error, reason} ->
            {:error, reason,
             Map.merge(evidence, %{members_status: status, result: "malformed_member_sample"})}
        end

      {:ok, %{status: status}} ->
        {:error, {:preflight_failed, :members, status},
         Map.merge(evidence, %{members_status: status, result: "members_unavailable"})}

      {:error, _reason} ->
        {:error, {:preflight_transport, :members},
         Map.put(evidence, :result, "members_transport_failure")}

      _other ->
        {:error, :malformed_preflight_response,
         Map.put(evidence, :result, "malformed_members_response")}
    end
  end

  defp validate_preflight_page(members) when is_list(members) and length(members) <= 1 do
    with {:ok, _users} <- recognition_users(members), do: {:ok, length(members)}
  end

  defp validate_preflight_page(_members), do: {:error, :malformed_member_page}

  defp create_preflight_receipt(options, status, evidence, result) do
    receipt(options).create(%{
      kind: :preflight,
      status: status,
      execution_id: options.execution_id,
      actor_id: options.actor_id,
      guild_id: options.guild_id,
      bot_application_id: options.bot_application_id,
      observed_bot_application_id: Map.get(evidence, :observed_application_id),
      tool_revision: options.tool_revision,
      evidence_digest: digest(evidence),
      record_count: Map.get(evidence, :sampled_count),
      result: result
    })
  end

  defp fetch_all(options, cursor, seen, acc) do
    case client(options).members(
           options.token,
           options.guild_id,
           cursor,
           @page_limit,
           request_options(options)
         ) do
      {:ok, %{status: 429, body: body}} ->
        with {:ok, retry_after} <- retry_after(body),
             :ok <- sleeper(options).sleep(retry_after) do
          fetch_all(options, cursor, seen, acc)
        end

      {:ok, %{status: status, body: page, headers: headers}} when status in 200..299 ->
        with :ok <- validate_page(page),
             {:ok, users} <- recognition_users(page),
             :ok <- cursor_progresses?(cursor, users),
             :ok <- reject_duplicates(users, seen),
             :ok <- wait_for_rate_limit(headers, options) do
          seen = Enum.reduce(users, seen, &MapSet.put(&2, &1.id))
          acc = acc ++ users

          case List.last(users) do
            nil -> {:ok, acc}
            %{id: next_cursor} -> fetch_all(options, next_cursor, seen, acc)
          end
        end

      {:ok, %{status: status}} ->
        {:error, {:guild_members_failed, status}}

      {:error, _reason} ->
        {:error, :guild_members_transport_failure}

      _other ->
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
             execution_id: options.execution_id,
             actor_id: options.actor_id,
             guild_id: options.guild_id,
             bot_application_id: options.bot_application_id,
             observed_bot_application_id: options.bot_application_id,
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
          case RosterPackage.delete(package_path) do
            :ok ->
              {:error, reason}

            {:error, cleanup_reason} ->
              {:error, {:package_cleanup_failed, reason, cleanup_reason}}
          end
      end
    end
  end

  defp validate_options(options) do
    required = [
      :token,
      :guild_id,
      :bot_application_id,
      :execution_id,
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

  defp validate_page(page) when is_list(page), do: :ok
  defp validate_page(_page), do: {:error, :malformed_member_page}

  defp recognition_users(page) do
    page
    |> Enum.reduce_while({:ok, []}, fn
      %{"user" => %{"id" => id, "username" => username} = user} = member, {:ok, users}
      when is_binary(id) and id != "" and is_binary(username) and username != "" ->
        global_name = Map.get(user, "global_name")
        nickname = Map.get(member, "nick")

        if nullable_string?(global_name) and nullable_string?(nickname) do
          recognition_user = %{
            id: id,
            username: username,
            global_name: global_name,
            nickname: nickname
          }

          {:cont, {:ok, [recognition_user | users]}}
        else
          {:halt, {:error, :malformed_roster_user}}
        end

      _member, _acc ->
        {:halt, {:error, :malformed_roster_user}}
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.reverse(users)}
      {:error, _reason} = error -> error
    end
  end

  defp nullable_string?(value), do: is_nil(value) or is_binary(value)

  defp reject_duplicates(users, seen) do
    ids = Enum.map(users, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)) and
         Enum.all?(ids, &(not MapSet.member?(seen, &1))),
       do: :ok,
       else: {:error, :duplicate_roster_user}
  end

  defp cursor_progresses?(nil, _users), do: :ok

  defp cursor_progresses?(cursor, users) do
    if Enum.any?(users, &(&1.id == cursor)),
      do: {:error, :cursor_non_progress},
      else: :ok
  end

  defp retry_after(%{"retry_after" => seconds}) when is_number(seconds) and seconds >= 0,
    do: {:ok, ceil(milliseconds(seconds))}

  defp retry_after(_body), do: {:error, :malformed_rate_limit_response}

  defp wait_for_rate_limit(headers, options) do
    remaining = header(headers, "x-ratelimit-remaining")
    reset_after = header(headers, "x-ratelimit-reset-after")

    case {parse_remaining(remaining), parse_reset_after(reset_after)} do
      {{:ok, nil}, {:ok, nil}} ->
        :ok

      {{:ok, count}, {:ok, nil}} when is_integer(count) and count > 0 ->
        :ok

      {{:ok, 0}, {:ok, seconds}} when is_number(seconds) ->
        sleeper(options).sleep(ceil(milliseconds(seconds)))

      {{:ok, count}, {:ok, _seconds}} when is_integer(count) and count > 0 ->
        :ok

      _invalid ->
        {:error, :malformed_rate_limit_headers}
    end
  end

  defp parse_remaining(nil), do: {:ok, nil}

  defp parse_remaining(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> {:ok, count}
      _invalid -> :error
    end
  end

  defp parse_remaining(_value), do: :error

  defp parse_reset_after(nil), do: {:ok, nil}

  defp parse_reset_after(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 -> {:ok, seconds}
      _invalid -> :error
    end
  end

  defp parse_reset_after(_value), do: :error

  defp milliseconds(seconds), do: seconds * 1_000

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: List.first(List.wrap(value))
    end)
  end

  defp support_safe_reason({:preflight_failed, endpoint, status}),
    do: "#{endpoint} preflight unavailable (HTTP #{status})"

  defp support_safe_reason(:unexpected_bot_application),
    do: "bot application identity did not match"

  defp support_safe_reason(_reason), do: "preflight verification failed"

  defp digest(term),
    do: :crypto.hash(:sha256, Jason.encode!(term)) |> Base.encode16(case: :lower)

  defp client(options), do: Map.get(options, :client, RosterClient)
  defp receipt(options), do: Map.get(options, :receipt_store, RosterReceipts)
  defp execution_store(options), do: Map.get(options, :execution_store, RosterExecutions)
  defp sleeper(options), do: Map.get(options, :sleeper, Dhc.Discord.RosterCapture.Sleeper)
  defp request_options(options), do: Map.get(options, :request_options, [])
end
