defmodule Dhc.Email.OfferRoundWorker do
  @moduledoc """
  Durable delivery of Beginners' Workshop offer-round Contact emails only.

  IntakeEmails prepares the envelopes; enqueue/2 freezes ordered chunks of 100
  in the causing command's transaction. The whole envelope (including sender,
  subject, template, recipient and Reply-To) is purpose-sealed for 24 hours.
  There is no mutable-domain read on delivery and no regrouping on retry.

  Resend's default strict validation rejects the entire request. We deliberately
  do not split even deterministic rejections: a terminal report names the round,
  chunk and affected count for operator reconciliation. A ledger occasion still
  means queued, not delivered. Unknown outcomes retry the identical request/key.
  The delivery window starts at enqueue, conservatively before provider key
  retention starts; expired work requires reconciliation, never a fresh key.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  require Logger

  alias Dhc.Email.Mailer
  alias Swoosh.Email

  @salt "dhc.email.offer_round envelopes v1"
  @lifetime 24 * 60 * 60

  @type plan :: {:planned, Email.t()}

  @doc false
  @spec prepare(String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, plan()} | {:error, :invalid_offer_round_envelope}
  def prepare(recipient, subject, variables, reply_to) do
    from = Application.get_env(:dhc, :email_from, "dev@dhc.local")

    reply_to =
      reply_to || Application.get_env(:dhc, :email_reply_to, "contact@dublinhemaclub.com")

    if address?(recipient) and sender?(from) and address?(reply_to) and
         is_binary(subject) and String.trim(subject) != "" and
         not String.contains?(subject, ["\r", "\n"]) do
      email =
        Email.new()
        |> Email.from(from)
        |> Email.to(recipient)
        |> Email.reply_to(reply_to)
        |> Email.subject(subject)
        |> Email.put_provider_option(:template, %{
          id: "beginners-workshop-action",
          variables: variables
        })
        |> decorate_for_dev(recipient, variables)

      {:ok, {:planned, email}}
    else
      {:error, :invalid_offer_round_envelope}
    end
  end

  defp decorate_for_dev(email, recipient, variables) do
    adapter = :dhc |> Application.get_env(Mailer, []) |> Keyword.get(:adapter)

    if adapter == Swoosh.Adapters.Resend do
      email
    else
      summary = %{
        email: recipient,
        transactional_id: "beginnersWorkshopAction",
        data_variables: variables
      }

      Email.text_body(email, Jason.encode!(summary, pretty: true))
    end
  end

  @doc false
  @spec enqueue(Ecto.UUID.t(), [plan() | :no_recipient]) :: :ok | {:error, Ecto.Changeset.t()}
  def enqueue(round_id, plans) do
    unless Dhc.Repo.in_transaction?(),
      do: raise("Offer-round enqueue requires a command transaction")

    plans
    |> Enum.flat_map(fn
      {:planned, %Email{} = email} -> [email]
      :no_recipient -> []
    end)
    |> Enum.chunk_every(100)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {emails, chunk}, :ok ->
      key = "beginners-offer-round:#{round_id}:#{chunk}"
      # The safety margin also bounds requests admitted just before expiry.
      deadline = System.system_time(:second) + @lifetime - 60
      frozen = %{emails: emails, key: key, deadline: deadline}

      args = %{
        "round_id" => round_id,
        "chunk" => chunk,
        "count" => length(emails),
        "sealed_envelopes" => Plug.Crypto.encrypt(secret(), @salt, frozen)
      }

      case args |> new() |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    with {:ok, frozen} <- unseal(job.args),
         :ok <- within_window(frozen.deadline) do
      frozen.emails
      |> Enum.map(fn email ->
        email
        |> Email.put_provider_option(:idempotency_key, frozen.key)
        |> Email.put_provider_option(:delivery_deadline, frozen.deadline)
      end)
      |> deliver()
      |> outcome(job)
    else
      {:error, reason} -> terminal(job, reason)
    end
  end

  defp unseal(%{
         "sealed_envelopes" => sealed,
         "round_id" => round,
         "chunk" => chunk,
         "count" => count
       })
       when is_binary(sealed) and is_binary(round) and count in 1..100 do
    key = "beginners-offer-round:#{round}:#{chunk}"

    case Plug.Crypto.decrypt(secret(), @salt, sealed, max_age: @lifetime) do
      {:ok, %{emails: emails, key: ^key, deadline: deadline} = frozen}
      when is_list(emails) and length(emails) == count and is_integer(deadline) ->
        {:ok, frozen}

      {:error, :expired} ->
        {:error, :expired_delivery}

      _ ->
        {:error, :invalid_batch}
    end
  end

  defp unseal(_args), do: {:error, :invalid_batch}

  defp within_window(deadline) do
    if System.system_time(:second) < deadline, do: :ok, else: {:error, :expired_delivery}
  end

  defp deliver(emails) do
    adapter = :dhc |> Application.get_env(Mailer, []) |> Keyword.get(:adapter)

    result =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :deliver_many, 2) do
        Mailer.deliver_many(emails)
      else
        # Mailpit has no batch API. Production never uses this fallback.
        Enum.reduce_while(emails, {:ok, []}, &deliver_one/2)
      end

    validate_receipts(result, adapter)
  end

  defp validate_receipts({:ok, receipts} = result, Swoosh.Adapters.Resend) do
    if Enum.all?(receipts, &receipt?/1), do: result, else: {:error, :invalid_provider_response}
  end

  defp validate_receipts(result, _adapter), do: result

  defp receipt?(%{id: id}) when is_binary(id) and id != "", do: true
  defp receipt?(_receipt), do: false

  defp deliver_one(email, {:ok, receipts}) do
    case Mailer.deliver(email) do
      {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
      error -> {:halt, error}
    end
  end

  defp outcome({:ok, receipts}, %{args: %{"count" => count}}) when length(receipts) == count,
    do: :ok

  defp outcome({:ok, _receipts}, job), do: retry(job, :invalid_provider_response)

  defp outcome({:error, :invalid_provider_response}, job),
    do: retry(job, :invalid_provider_response)

  defp outcome({:error, :delivery_window_expired}, job), do: terminal(job, :expired_delivery)

  # A concurrent request with this same key isn't a payload rejection.
  defp outcome({:error, {409, %{"name" => "concurrent_idempotent_requests"}}}, job),
    do: retry(job, 409)

  defp outcome({:error, {status, _body}}, job) when status in 400..499 and status != 429,
    do: terminal(job, {:provider_rejected, status})

  defp outcome({:error, {status, _body}}, job) when status in 500..599 or status == 429,
    do: retry(job, status)

  defp outcome({:error, _reason}, job), do: retry(job, :transport_failure)

  defp retry(job, status) do
    if job.attempt >= job.max_attempts do
      terminal(job, {:exhausted_delivery, status})
    else
      {:error, {:offer_round_delivery, status}}
    end
  end

  defp terminal(job, reason) do
    context = %{
      oban_job_id: job.id,
      oban_attempt: job.attempt,
      oban_queue: job.queue,
      oban_worker: "Dhc.Email.OfferRoundWorker",
      round_id: job.args["round_id"],
      chunk: job.args["chunk"],
      count: job.args["count"],
      delivery_failure: failure_name(reason),
      provider_status: failure_status(reason)
    }

    Logger.error("Offer-round email delivery requires reconciliation", Map.to_list(context))

    Sentry.capture_message(
      "Offer-round email delivery requires reconciliation: #{inspect(reason)}",
      level: :error,
      extra: context
    )

    {:cancel, reason}
  end

  defp failure_name({name, _status}), do: name
  defp failure_name(name), do: name
  defp failure_status({_name, status}) when is_integer(status), do: status
  defp failure_status(_reason), do: nil

  defp address?(value) when is_binary(value), do: value =~ ~r/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/
  defp address?(_value), do: false

  defp sender?({name, address}) when is_binary(name) do
    address?(address) and not String.contains?(name, ["\r", "\n"])
  end

  defp sender?(sender) when is_binary(sender) do
    case Regex.run(~r/^[^<>\r\n]+<([^<>]+)>$/, sender, capture: :all_but_first) do
      [address] -> address?(address)
      nil -> address?(sender)
    end
  end

  defp sender?(_sender), do: false
  defp secret, do: DhcWeb.Endpoint.config(:secret_key_base)
end
