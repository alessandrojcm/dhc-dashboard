defmodule Dhc.BeginnersWorkshops.IntakeReplies do
  @moduledoc """
  Intake Replies (ADR 0030): the per-email Reply-To credential for Intake
  Emails (ALE-407), and receiving and forwarding the replies sent to it
  (ALE-409).

  ## Reply addresses (ALE-407)

  Only token hashes are persisted; the address itself is carried to the
  email worker in a sealed Oban argument.

  ## Receiving and forwarding (ALE-409)

  `record_received/2` is all the Resend webhook does: it resolves the
  recipients to a binding, records one `IntakeReply` row (unique on the
  Resend email id, so a redelivered webhook changes nothing) and queues one
  `Workers.ReplyWorker` job, whose only argument is the Resend email id.

  `forward/2` (the worker's body) forwards the reply exactly once to the
  club inbox (`IntakeReplies.Forward` builds it): it reads the received email
  and its attachments through `Dhc.Resend.Receiving`, sends under the key
  `intake-reply-forward:<resend email id>` and records the forward's sent id
  and time, so a retried job never sends a second forward. Every recognised
  reply is `[Needs you]` until Reply Actions exist (ALE-411); a reply to an
  address that resolves to nothing is `[Unrecognised]`. On the job's last
  attempt a reply that still cannot be read is forwarded as the banner alone,
  and a forward that cannot be sent at all raises a keyed coordinator alert
  (`{:alert_reply_waiting, resend_email_id}`) saying a reply is waiting in
  Resend.

  Reply addresses and bodies never reach a log, Sentry or Oban args: logs
  carry only the Resend email id and closed reasons.
  """

  import Ecto.Query

  require Logger

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{IntakeReply, IntakeReplyAddress}
  alias Dhc.BeginnersWorkshops.IntakeReplies.Forward
  alias Dhc.BeginnersWorkshops.Workers.ReplyWorker
  alias Dhc.Email.Mailer
  alias Dhc.Repo
  alias Dhc.Resend.Receiving
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @token_bytes 20
  @domain_regex ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/
  @local_part_regex ~r/\A[a-zA-Z0-9]+\z/

  @doc false
  @spec reply_to(WaitlistEntry.t(), Ecto.UUID.t() | nil, String.t()) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t()}
  def reply_to(%WaitlistEntry{id: waitlist_id}, intake_id, email_type)
      when is_binary(email_type) do
    case reply_domain() do
      nil ->
        {:ok, nil}

      domain ->
        token = random_token()

        binding = %IntakeReplyAddress{
          waitlist_id: waitlist_id,
          intake_id: intake_id,
          email_type: email_type,
          token_hash: token_hash(token)
        }

        case binding |> IntakeReplyAddress.changeset() |> Repo.insert() do
          {:ok, _binding} -> {:ok, "#{token}@#{domain}"}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc "Resolves a Reply-To address without accepting addresses on other domains."
  @spec resolve(term()) :: {:ok, IntakeReplyAddress.t()} | :unknown
  def resolve(address) when is_binary(address) do
    with domain when is_binary(domain) <- reply_domain(),
         [local_part, supplied_domain] <- String.split(address, "@"),
         true <- Regex.match?(@local_part_regex, local_part),
         true <- String.downcase(supplied_domain) == domain do
      hash = local_part |> String.downcase() |> token_hash()

      case Repo.one(
             from(binding in IntakeReplyAddress,
               where: binding.token_hash == ^hash,
               preload: [:waitlist_entry, :intake]
             )
           ) do
        %IntakeReplyAddress{} = binding -> {:ok, binding}
        nil -> :unknown
      end
    else
      _not_a_reply_address -> :unknown
    end
  end

  def resolve(_address), do: :unknown

  @doc """
  Deletes the person's reply-address bindings and the Intake Replies sent to
  them, inside the caller's (hard delete's) transaction.
  """
  @spec delete_for_person(Ecto.UUID.t()) :: non_neg_integer()
  def delete_for_person(waitlist_id) when is_binary(waitlist_id) do
    Repo.delete_all(
      from(reply in IntakeReply,
        join: binding in assoc(reply, :reply_address),
        where: binding.waitlist_id == ^waitlist_id
      )
    )

    {deleted, _rows} =
      Repo.delete_all(
        from(binding in IntakeReplyAddress, where: binding.waitlist_id == ^waitlist_id)
      )

    deleted
  end

  # ── Receiving (ALE-409) ─────────────────────────────────────────

  @doc """
  Records one received reply from an `email.received` webhook's `data` and
  queues its forward. A redelivery finds the row already recorded and the
  job already queued, and changes nothing.
  """
  @spec record_received(map(), DateTime.t()) ::
          {:ok, :recorded | :duplicate} | {:error, :invalid_payload | :enqueue_failed}
  def record_received(data, now \\ DateTime.utc_now())

  def record_received(%{"email_id" => resend_email_id} = data, now)
      when is_binary(resend_email_id) do
    if Receiving.valid_id?(resend_email_id) do
      binding = data |> recipients() |> Enum.find_value(&resolved/1)

      {inserted, _rows} =
        Repo.insert_all(
          IntakeReply,
          [
            %{
              resend_email_id: resend_email_id,
              reply_address_id: binding && binding.id,
              received_at: now,
              outcome: "pending",
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: :nothing,
          conflict_target: :resend_email_id
        )

      case %{"resend_email_id" => resend_email_id} |> ReplyWorker.new() |> Oban.insert() do
        {:ok, _job} -> {:ok, if(inserted == 1, do: :recorded, else: :duplicate)}
        {:error, _changeset} -> {:error, :enqueue_failed}
      end
    else
      {:error, :invalid_payload}
    end
  end

  def record_received(_data, _now), do: {:error, :invalid_payload}

  defp recipients(data) do
    ["to", "cc", "bcc", "received_for"]
    |> Enum.flat_map(fn key -> List.wrap(data[key]) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&bare_address/1)
  end

  # `Name <address>` → `address`.
  defp bare_address(recipient) do
    case Regex.run(~r/<([^<>]+)>\s*\z/, recipient) do
      [_match, address] -> String.trim(address)
      nil -> String.trim(recipient)
    end
  end

  defp resolved(address) do
    case resolve(address) do
      {:ok, binding} -> binding
      :unknown -> nil
    end
  end

  # ── Forwarding (ALE-409) ────────────────────────────────────────

  @doc """
  Forwards the recorded reply once. Options:

    * `:final` — this is the job's last attempt: a reply that cannot be read
      is forwarded as the banner alone, and a forward that cannot be sent
      raises the coordinator alert instead of failing;
    * `:max_bytes` — the size limit (default Resend's 40 MB).

  Returns `{:error, reason}` only when another attempt should try again.
  """
  @spec forward(String.t(), keyword()) ::
          {:ok, :forwarded | :already_forwarded | :alerted} | {:error, term()}
  def forward(resend_email_id, opts \\ []) when is_binary(resend_email_id) do
    final? = Keyword.get(opts, :final, false)
    max_bytes = Keyword.get(opts, :max_bytes, Forward.max_bytes())

    case load(resend_email_id) do
      nil ->
        {:error, :reply_not_found}

      %IntakeReply{forwarded_at: %DateTime{}} ->
        {:ok, :already_forwarded}

      %IntakeReply{} = reply ->
        context = context(reply)

        case build(context, max_bytes) do
          {:ok, email} -> send_forward(reply, context, email, final?)
          {:error, reason} when final? -> forward_unreadable(reply, context, reason)
          {:error, _reason} = error -> error
        end
    end
  end

  defp load(resend_email_id) do
    Repo.one(
      from(reply in IntakeReply,
        where: reply.resend_email_id == ^resend_email_id,
        preload: [reply_address: :intake]
      )
    )
  end

  defp context(%IntakeReply{resend_email_id: id, reply_address: nil}),
    do: %{resend_email_id: id, tag: :unrecognised, person: nil}

  defp context(%IntakeReply{resend_email_id: id, reply_address: binding}) do
    %{
      resend_email_id: id,
      tag: :needs_you,
      person: %{
        name: person_name(binding.waitlist_id),
        email_type: binding.email_type,
        workshop_id: binding.intake && binding.intake.workshop_id
      }
    }
  end

  defp person_name(waitlist_id) do
    from(p in UserProfile,
      where: p.waitlist_id == ^waitlist_id,
      limit: 1,
      select: {p.first_name, p.last_name}
    )
    |> Repo.one()
    |> case do
      {first, last} ->
        case [first, last] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
          "" -> "someone on the Waitlist"
          name -> name
        end

      nil ->
        "someone on the Waitlist"
    end
  end

  # The best forward that fits: rebuilt, else the original as `.eml`, else
  # the banner alone when even the original is too large.
  defp build(context, max_bytes) do
    with {:ok, received} <- Receiving.get_email(context.resend_email_id) do
      case rebuild(context, received, max_bytes) do
        {:ok, email} -> {:ok, email}
        {:error, _cannot_rebuild} -> with_original(context, received, max_bytes)
      end
    end
  end

  defp rebuild(context, received, max_bytes) do
    with {:ok, attachments} <- Receiving.list_attachments(context.resend_email_id),
         :ok <- fits(Forward.rebuilt_bytes(received, attachments), max_bytes),
         {:ok, downloaded} <- download_all(attachments) do
      {:ok, Forward.rebuilt(context, received, downloaded)}
    end
  end

  defp download_all(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      with url when is_binary(url) <- attachment["download_url"],
           {:ok, content} <- Receiving.download(url) do
        {:cont, {:ok, [{attachment, content} | acc]}}
      else
        _failed -> {:halt, {:error, :attachment_unavailable}}
      end
    end)
    |> case do
      {:ok, downloaded} -> {:ok, Enum.reverse(downloaded)}
      error -> error
    end
  end

  defp with_original(context, received, max_bytes) do
    with %{"download_url" => url} when is_binary(url) <- received["raw"],
         {:ok, raw} <- Receiving.download(url) do
      case fits(Forward.original_bytes(raw), max_bytes) do
        :ok -> {:ok, Forward.with_original(context, received, raw)}
        {:error, :too_large} -> {:ok, Forward.banner_only(context, received, :too_large)}
      end
    else
      {:error, _reason} = error -> error
      _no_raw -> {:error, :original_unavailable}
    end
  end

  defp fits(bytes, max_bytes) when bytes <= max_bytes, do: :ok
  defp fits(_bytes, _max_bytes), do: {:error, :too_large}

  defp forward_unreadable(reply, context, reason) do
    Logger.warning("[intake-replies] Reply could not be read; forwarding the banner alone",
      resend_email_id: reply.resend_email_id,
      reason: inspect(reason)
    )

    send_forward(reply, context, Forward.banner_only(context, nil, :unavailable), true,
      reason: "retries_exhausted"
    )
  end

  defp send_forward(reply, context, email, final?, opts \\ []) do
    case deliver(email) do
      {:ok, sent_id} ->
        record_forward(reply, context, sent_id, Keyword.get(opts, :reason))
        {:ok, :forwarded}

      {:error, reason} when final? ->
        alert(reply, reason)

      {:error, reason} ->
        Logger.warning("[intake-replies] Forward could not be sent",
          resend_email_id: reply.resend_email_id,
          reason: inspect(reason)
        )

        {:error, :forward_failed}
    end
  end

  # The sent id, when the adapter reports one. A Resend 409 for a reused key
  # with a different payload means an earlier attempt's forward was accepted.
  defp deliver(email) do
    case Mailer.deliver(email) do
      {:ok, %{id: id}} when is_binary(id) -> {:ok, id}
      {:ok, _receipt} -> {:ok, nil}
      {:error, {409, %{"name" => "invalid_idempotent_request"}}} -> {:ok, nil}
      {:error, {status, _body}} when is_integer(status) -> {:error, {:http_status, status}}
      {:error, _reason} -> {:error, :delivery_failed}
    end
  end

  defp record_forward(reply, context, sent_id, reason) do
    {outcome, default_reason} =
      case context.tag do
        :unrecognised -> {"unrecognised", "unknown_address"}
        # Reply Actions are not available yet (ALE-411).
        :needs_you -> {"needs_you", "reply_actions_off"}
      end

    set_outcome(reply, outcome, reason || default_reason,
      forward_sent_id: sent_id,
      forwarded_at: DateTime.utc_now()
    )
  end

  defp alert(reply, reason) do
    Logger.error("[intake-replies] Forward could not be sent; alerting the coordinators",
      resend_email_id: reply.resend_email_id,
      reason: inspect(reason)
    )

    case BeginnersWorkshops.execute(:system, {:alert_reply_waiting, reply.resend_email_id}) do
      {:ok, _outcome} ->
        set_outcome(reply, "needs_you", "forward_failed", [])
        {:ok, :alerted}

      {:error, _reason} = error ->
        error
    end
  end

  defp set_outcome(reply, outcome, reason, changes) do
    Repo.update_all(
      from(r in IntakeReply, where: r.id == ^reply.id and is_nil(r.forwarded_at)),
      set: [outcome: outcome, outcome_reason: reason, updated_at: DateTime.utc_now()] ++ changes
    )
  end

  defp random_token do
    :crypto.strong_rand_bytes(@token_bytes)
    |> Base.encode32(case: :lower, padding: false)
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  defp reply_domain do
    case Application.get_env(:dhc, :intake_reply_domain) do
      domain when is_binary(domain) ->
        normalized = domain |> String.trim() |> String.downcase()
        if Regex.match?(@domain_regex, normalized), do: normalized

      _unset_or_invalid ->
        nil
    end
  end
end
