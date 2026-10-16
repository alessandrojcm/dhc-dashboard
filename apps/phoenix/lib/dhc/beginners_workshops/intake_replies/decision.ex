defmodule Dhc.BeginnersWorkshops.IntakeReplies.Decision do
  @moduledoc """
  The step between receiving an Intake Reply and forwarding it (ALE-411,
  ADR 0030): decide whether the reply leads to a **Reply Action** and, if
  so, run it through `Dhc.BeginnersWorkshops.execute/3` as
  `{:intake_reply, intake_reply_id}`. `IntakeReplies.forward/2` calls
  `decide/3` with the received email before it builds the forward, whose
  tag then says what happened.

  In order, each step that ends without a Reply Action records its outcome
  and reason on the `IntakeReply` row:

    1. an address that matches nobody — `unrecognised` / `unknown_address`;
    2. automated mail (`Auto-Submitted` other than `no`, `X-Autoreply`,
       `Precedence: auto_reply | bulk | junk`) — `automated` / `auto_reply`,
       Jev not called;
    3. a From that is not the person's Waitlist email (bare address,
       case-insensitive) — `needs_you` / `sender_mismatch`;
    4. no new text (`ReplyText.extract/1` is `:empty`) — `needs_you` /
       `empty_reply`, Jev not called;
    5. no intent that could lead to a command for the person now
       (`no_reply_action`), or none of those switched on
       (`reply_actions_off`) — Jev not called, so no reply text leaves
       Phoenix for nothing;
    6. classify (`Classifier.classify/3`) over the offered intents, and map
       intent, confidence and money through `ReplyActions.decide/3`
       (`intent_disabled`, `below_threshold`, `money_unclear`, …).

  A chosen Reply Action is written to the row (`command`, with Jev's
  answers) **before** it runs, so a retried job never classifies again;
  then the boundary decides: `:done` is `done`, `:already_done` or a
  refusal is `refused` with the reason. A retry that finds the Intake
  history row naming this reply knows the action already ran. (A person
  command with no open Intake writes no history row; a retry after a crash
  between its commit and the row update finds it `already_done`. A restore
  writes no history row either, so it stamps the reply's
  `action_committed_at` in its own transaction and a retry reports it done.)

  A Jev failure returns `{:error, :classifier_failed}` so the job retries;
  on the last attempt (`final: true`) it is `needs_you` /
  `classifier_failed`. A classifier that is not configured is
  `classifier_unavailable` at once.

  Nothing here logs reply text, an address or Jev's request.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{CarriedFee, Clock, Intake, IntakeEvent, IntakeReply}
  alias Dhc.BeginnersWorkshops.IntakeReplies.{Classifier, ReplyActions, ReplyText}
  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @automated_precedence ~w(auto_reply bulk junk)

  @doc """
  Decides (and runs) the reply's Reply Action unless it was already
  decided. `received` is Resend's received email. Options: `:final` (the
  job's last attempt) and `:clock` (passed to the boundary).
  """
  @spec decide(IntakeReply.t(), map(), keyword()) ::
          {:ok, IntakeReply.t()} | {:error, :classifier_failed}
  def decide(%IntakeReply{decided_at: %DateTime{}} = reply, _received, _opts), do: {:ok, reply}

  # Chosen on an earlier attempt, not yet recorded as run.
  def decide(%IntakeReply{command: command} = reply, _received, opts) when is_binary(command),
    do: reply |> act(chosen(reply), opts) |> ok()

  def decide(%IntakeReply{reply_address: nil} = reply, _received, _opts),
    do: reply |> record("unrecognised", "unknown_address") |> ok()

  def decide(%IntakeReply{reply_address: binding} = reply, received, opts) do
    cond do
      automated?(received) ->
        reply |> record("automated", "auto_reply") |> ok()

      not same_address?(received["from"], binding.waitlist_entry.email) ->
        reply |> record("needs_you", "sender_mismatch") |> ok()

      true ->
        case ReplyText.extract(%{text: received["text"], html: received["html"]}) do
          {:ok, text} -> classify(reply, text, opts)
          :empty -> reply |> record("needs_you", "empty_reply") |> ok()
        end
    end
  end

  @doc """
  The last attempt could not read the reply: an undecided reply needs the
  coordinator (`retries_exhausted`; an unknown address stays
  `unrecognised`). A decided one keeps its outcome.
  """
  @spec unread(IntakeReply.t()) :: IntakeReply.t()
  def unread(%IntakeReply{decided_at: nil, command: nil, reply_address: nil} = reply),
    do: record(reply, "unrecognised", "unknown_address")

  def unread(%IntakeReply{decided_at: nil, command: nil} = reply),
    do: record(reply, "needs_you", "retries_exhausted")

  def unread(%IntakeReply{} = reply), do: reply

  # ── Classifying ─────────────────────────────────────────────────

  defp classify(%IntakeReply{reply_address: binding} = reply, text, opts) do
    facts = person_facts(binding, opts)
    offered = ReplyActions.offered(facts)
    config = ReplyActions.config()

    cond do
      offered == [] ->
        reply |> record("needs_you", "no_reply_action") |> ok()

      not ReplyActions.any_enabled?(offered, config) ->
        reply |> record("needs_you", "reply_actions_off") |> ok()

      true ->
        reply
        |> classified(Classifier.classify(text, binding.email_type, offered), facts, config, opts)
    end
  end

  defp classified(reply, {:ok, classification}, facts, config, opts),
    do: decided(reply, classification, ReplyActions.decide(classification, facts, config), opts)

  defp classified(reply, {:error, reason}, _facts, _config, _opts)
       when reason in [:not_configured, :invalid_input],
       do: reply |> record("needs_you", "classifier_unavailable") |> ok()

  defp classified(reply, {:error, _reason}, _facts, _config, opts) do
    if Keyword.get(opts, :final, false),
      do: reply |> record("needs_you", "classifier_failed") |> ok(),
      else: {:error, :classifier_failed}
  end

  defp decided(reply, classification, {:none, reason}, _opts),
    do: reply |> record("needs_you", reason, answers(classification)) |> ok()

  defp decided(reply, classification, {:ok, action}, opts) do
    reply = choose(reply, classification, action)
    reply |> act(action, opts) |> ok()
  end

  defp answers(classification) do
    [
      intent: classification.intent,
      intent_probabilities: classification.probabilities,
      intent_confidence: classification.confidence / 1,
      money_back: classification.money_back / 1,
      model: classification.model
    ]
  end

  # The person's state for the table, read without a lock: the boundary's
  # locked re-check decides (retention on the same clock it is passed).
  defp person_facts(binding, opts) do
    waitlist_id = binding.waitlist_id
    entry = binding.waitlist_entry

    open =
      Repo.one(
        from(i in Intake,
          where: i.waitlist_id == ^waitlist_id and i.state in ^Intake.open_states(),
          select: %{id: i.id, state: i.state},
          limit: 1
        )
      )

    %ReplyActions{
      binding_open: open != nil and open.id == binding.intake_id,
      open_intake: open && open.state,
      held_fee:
        Repo.exists?(
          from(f in CarriedFee, where: f.waitlist_id == ^waitlist_id and f.status == "held")
        ),
      standing: entry.status,
      restorable: restorable?(entry, opts)
    }
  end

  defp restorable?(%WaitlistEntry{status: "removed", removed_at: %DateTime{} = at}, opts),
    do: Waitlist.restorable?(at, Clock.read(Clock.from_opts(opts)).now)

  defp restorable?(_entry, _opts), do: false

  # ── Acting ──────────────────────────────────────────────────────

  @commands %{
    "decline" => {:intake, :decline},
    "defer" => {:intake, :defer},
    "cancel_with_refund" => {:intake, :cancel_with_refund},
    "resend_link" => {:intake, :resend_link},
    "withdraw" => {:person, :withdraw},
    "refund_carried_fee" => {:person, :refund_carried_fee},
    "restore_person" => {:person, :restore_person}
  }

  defp chosen(%IntakeReply{command: command}), do: Map.fetch!(@commands, command)

  # The Intake history row naming this reply, or the reply's own
  # `action_committed_at` (a restore, which writes no history row), means an
  # earlier attempt's Reply Action committed.
  defp act(reply, action, opts) do
    {outcome, reason} =
      if committed?(reply), do: {"done", nil}, else: reply |> run(action, opts) |> outcome()

    record(reply, outcome, reason)
  end

  defp run(%IntakeReply{id: id, reply_address: binding}, {:intake, command}, opts) do
    intake = binding.intake

    BeginnersWorkshops.execute(
      {:intake_reply, id},
      {command, intake.workshop_id, intake.id, %{}},
      clock_opts(opts)
    )
  end

  # A Reply Action never forfeits: a withdrawal always takes the refund.
  defp run(%IntakeReply{id: id, reply_address: binding}, {:person, :withdraw}, opts),
    do:
      BeginnersWorkshops.execute(
        {:intake_reply, id},
        {:withdraw, binding.waitlist_id, %{refund: true}},
        clock_opts(opts)
      )

  defp run(%IntakeReply{id: id, reply_address: binding}, {:person, :refund_carried_fee}, opts),
    do:
      BeginnersWorkshops.execute(
        {:intake_reply, id},
        {:refund_carried_fee, binding.waitlist_id, %{}},
        clock_opts(opts)
      )

  defp run(%IntakeReply{id: id, reply_address: binding}, {:person, :restore_person}, opts),
    do:
      BeginnersWorkshops.execute(
        {:intake_reply, id},
        {:restore_person, binding.waitlist_id},
        clock_opts(opts)
      )

  defp clock_opts(opts), do: Keyword.take(opts, [:clock])

  defp outcome({:ok, %{outcome: :already_done}}), do: {"refused", "already_done"}
  defp outcome({:ok, _view}), do: {"done", nil}
  defp outcome({:error, reason}) when is_atom(reason), do: {"refused", Atom.to_string(reason)}
  defp outcome({:error, _changeset}), do: {"refused", "invalid"}

  defp committed?(%IntakeReply{action_committed_at: %DateTime{}}), do: true

  defp committed?(%IntakeReply{id: id}),
    do: Repo.exists?(from(e in IntakeEvent, where: e.intake_reply_id == ^id))

  # ── Recording ───────────────────────────────────────────────────

  defp choose(reply, classification, {_kind, command}) do
    changes = answers(classification) ++ [command: Atom.to_string(command)]
    write(reply, changes)
  end

  defp record(reply, outcome, reason, changes \\ []) do
    write(
      reply,
      [outcome: outcome, outcome_reason: reason, decided_at: DateTime.utc_now()] ++ changes
    )
  end

  defp write(reply, changes) do
    Repo.update_all(
      from(r in IntakeReply, where: r.id == ^reply.id and is_nil(r.decided_at)),
      set: changes ++ [updated_at: DateTime.utc_now()]
    )

    %{Repo.reload!(reply) | reply_address: reply.reply_address}
  end

  defp ok(reply), do: {:ok, reply}

  # ── Reading the email ───────────────────────────────────────────

  @doc """
  Whether the received email is automated: `Auto-Submitted` other than
  `no`, any `X-Autoreply`, or `Precedence` `auto_reply`, `bulk` or `junk`.
  """
  @spec automated?(map()) :: boolean()
  def automated?(received) do
    headers = headers(received)
    auto_submitted = headers |> Map.get("auto-submitted") |> token()

    (auto_submitted != nil and auto_submitted != "no") or
      Map.has_key?(headers, "x-autoreply") or
      (headers |> Map.get("precedence") |> token()) in @automated_precedence
  end

  # Resend lists headers as a map; names are compared lowercased, and a
  # repeated header may arrive as a list.
  defp headers(%{"headers" => headers}) when is_map(headers),
    do: Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), value} end)

  defp headers(_received), do: %{}

  defp token([value | _rest]), do: token(value)

  defp token(value) when is_binary(value) do
    case value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() do
      "" -> nil
      token -> token
    end
  end

  defp token(_value), do: nil

  defp same_address?(from, email) do
    from = canonical(from)
    from != nil and from == canonical(email)
  end

  @doc "An address compared canonically: the bare address, trimmed and lowercased."
  @spec canonical(term()) :: String.t() | nil
  def canonical(address) when is_binary(address) do
    bare =
      case Regex.run(~r/<([^<>]+)>\s*\z/, address) do
        [_match, inner] -> inner
        nil -> address
      end

    case bare |> String.trim() |> String.downcase() do
      "" -> nil
      canonical -> canonical
    end
  end

  def canonical(_address), do: nil
end
