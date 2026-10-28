defmodule DhcWeb.SentryPrivacy do
  @moduledoc """
  Sentry's final event boundary. Intake URLs keep their existing redaction;
  email jobs additionally disclose only safe job context, never Oban's args,
  provider bodies, or the original exception's inspected payload.
  """

  alias DhcWeb.IntakeLinkPrivacy

  @email_worker "Dhc.Email.Worker"
  @safe_extra ~w(id attempt max_attempts queue worker tags oban_job_id oban_attempt oban_queue oban_worker transactional_id provider_status validation_errors)a
  @safe_metadata ~w(file line oban_job_id oban_attempt oban_queue oban_worker transactional_id provider_status)a

  @doc "Filters expected email retries and scrubs retained reports."
  def before_send(%Sentry.Event{} = event) do
    cond do
      not email_event?(event) -> IntakeLinkPrivacy.before_send(event)
      retrying_delivery?(event) -> nil
      true -> event |> scrub_email() |> IntakeLinkPrivacy.before_send()
    end
  end

  def before_send(event), do: IntakeLinkPrivacy.before_send(event)

  defp email_event?(event) do
    tags = string_keys(event.tags || %{})
    extra = event.extra || %{}
    metadata = extra[:logger_metadata] || %{}

    (tags["oban_worker"] || extra[:oban_worker] || extra[:worker] || metadata[:oban_worker]) ==
      @email_worker
  end

  defp retrying_delivery?(%{
         original_exception: %Oban.PerformError{reason: {:error, _}},
         integration_meta: %{oban: %{job: %Oban.Job{} = job}}
       }),
       do: job.attempt < job.max_attempts

  defp retrying_delivery?(_event), do: false

  defp scrub_email(event) do
    extra = event.extra || %{}
    safe = Map.take(extra, @safe_extra)
    safe = Map.merge(safe, provider_status(event.original_exception))

    safe =
      case extra[:args] do
        args when is_map(args) -> Map.put(safe, :args, safe_args(args))
        _ -> safe
      end

    safe =
      case extra[:logger_metadata] do
        metadata when is_map(metadata) ->
          Map.put(safe, :logger_metadata, Map.take(metadata, @safe_metadata))

        _ ->
          safe
      end

    exceptions = Enum.map(event.exception || [], &%{&1 | value: "Email job failed"})

    %{
      event
      | extra: safe,
        exception: exceptions,
        original_exception: nil,
        integration_meta: %{},
        breadcrumbs: [],
        user: %{},
        request: nil
    }
  end

  defp safe_args(args) do
    args = string_keys(args)

    %{
      transactional_id: args["transactional_id"],
      data_variable_keys: variable_keys(args),
      sealed_data_variables: args["sealed_data_variables"] not in [nil, false],
      sealed_reply_to: args["sealed_reply_to"] not in [nil, false]
    }
  end

  defp variable_keys(%{"data_variables" => variables}) when is_map(variables),
    do: Map.keys(variables)

  defp variable_keys(%{"data_variable_keys" => keys}) when is_list(keys), do: keys
  defp variable_keys(_args), do: []

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp provider_status(%Oban.PerformError{reason: {:error, {status, _}}}) when status in 400..599,
    do: %{provider_status: status}

  defp provider_status(_exception), do: %{}
end
