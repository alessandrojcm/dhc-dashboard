defmodule Dhc.Workshops.PaymentCommands do
  @moduledoc """
  ALE-340 (ADR 0027, finishing ADR 0012): the one implementation of every
  transaction that starts, concludes, cancels or refunds a Workshop payment.

  `Dhc.Workshops` keeps its caller-shaped public functions and delegates each
  of these to `execute/2`; `RefundWorker` and `RefundReconciliationWorker`
  only turn job arguments into a command, and Stripe `refund.*` events reach
  it through `Dhc.Workshops.apply_stripe_refund_event/1`. Workshop CRUD,
  publish, interest, attendance and read models stay in `Dhc.Workshops`.

  ## The protocol

  Every command body runs as

      with_locked(spec, fn locked ->
        # locked.workshop / .attempt / .registration / .refund were read
        # FOR UPDATE, in that order, inside one transaction
        decide from the locked rows (RefundPolicy, capacity, identity)
        write through transition/3 and persist/1
      end)

  **Lock order is part of the contract: Workshop → Payment Attempt →
  Registration → Refund.** `with_locked/2` is the only function here that
  takes a row lock, and it walks the levels in that order; a command may skip
  levels but can never lock upward. Commands that start from a Refund (the
  submission job, Stripe events, reconciliation) peek the Refund *unlocked*
  only to learn which Payment Attempt / Registration it points to, lock those
  in order, re-read the Refund under the lock, and retry from a fresh peek if
  it moved. Refund-only progression never takes the Workshop lock.

  **Stripe never runs inside a transaction.** A command reads or decides
  under the lock, commits, calls Stripe, and writes the result through
  `with_locked/2` again after an authoritative re-read. Duplicate provider
  side effects are prevented by the per-attempt
  (`workshop-payment-attempt:<id>`) and per-Refund (`workshop-refund:<id>`)
  idempotency keys; there is no lease, because concurrent callers for one
  attempt perform the same idempotent Stripe work.

  **One transition table** (`transition/3`) for every status write:

      Payment Attempt  pending → paid | policy_failed
                       paid    → registered | compensating | policy_failed
                       compensating → refunded
      Refund           pending    → processing | completed | failed | cancelled
                       processing → completed | failed | cancelled

  A non-terminal row may also be rewritten in its current status (identifiers,
  provider status, last error). Terminal rows — `registered`, `refunded`,
  `policy_failed`, and `completed`/`failed`/`cancelled` Refunds — never
  change, so a late Stripe event or a stale submission result is ignored.

  **Constraints are translated, never raised.** `persist/1` declares every
  unique index on the Payment Attempt, Registration and Refund tables and
  turns a violation into a reason the public functions already return
  (`:already_requested`, `:already_registered`, ...). The locks settle
  command-against-command; the indexes are the backstop for anything else.
  A violation aborts the Postgres transaction, so only writes persisted with
  `recoverable: true` (a savepoint) may be followed by more writes; every
  other translated violation rolls the command back.

  Refund eligibility is decided by `Dhc.Workshops.RefundPolicy` under the
  lock — the same predicates the advisory `refund_eligibility/1` uses.

  A Registration becomes `refunded` when its Refund obligation is recorded
  (CONTEXT.md); Stripe progress is a fact of the Refund.
  """

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  alias Dhc.Workshops.{
    ExternalUser,
    PaymentAttempt,
    Refund,
    RefundPolicy,
    RefundProjection,
    Registration,
    Workshop
  }

  alias Dhc.Workshops.Workers.RefundWorker

  @type user_id :: binary()

  @type actor ::
          {:member, user_id()}
          | {:coordinator, user_id()}
          | :external
          | :system

  @typedoc """
  `{:cancel_workshop, workshop_id, transition, registrations}` takes the
  Workshop status change as a function so it stays in `Dhc.Workshops` while
  running under the same Workshop lock as the Refund fan-out.
  `registrations` says whether the cancellation refunds every Registration it
  owes (`:refund_owed`, a coordinator's cancellation, which records them as
  the requester) or leaves Registrations untouched (`:keep`, allowed to the
  system).
  """
  @type command ::
          {:start_member_payment, workshop_id :: binary(), customer_id :: String.t() | nil}
          | {:start_external_payment, workshop_id :: binary(), payment_attempt_id :: binary(),
             return_url :: String.t()}
          | {:complete_member_payment, workshop_id :: binary(), payment_intent_id :: String.t()}
          | {:complete_external_payment, workshop_id :: binary(),
             checkout_session_id :: String.t()}
          | {:cancel_member_registration, workshop_id :: binary()}
          | {:request_refund, workshop_id :: binary(), registration_id :: binary(),
             reason :: String.t()}
          | {:cancel_workshop, workshop_id :: binary(),
             (Workshop.t() -> {:ok, Workshop.t()} | {:error, term()}), :refund_owed | :keep}
          | {:submit_refund, refund_id :: binary()}
          | {:apply_refund_update, stripe_refund :: map()}
          | :reconcile_refunds

  @member_commands ~w(start_member_payment complete_member_payment cancel_member_registration)a
  @external_commands ~w(start_external_payment complete_external_payment)a
  @coordinator_commands ~w(request_refund cancel_workshop)a
  @system_commands ~w(submit_refund apply_refund_update reconcile_refunds)a

  @workshop_registration_metadata_type "workshop_registration"
  @member_actor_type "member"
  @external_actor_type "external"

  @refund_peek_attempts 3

  @attempt_transitions %{
    "pending" => ~w(paid policy_failed),
    "paid" => ~w(registered compensating policy_failed),
    "compensating" => ~w(refunded)
  }

  # A payment in progress: not yet concluded with a Registration or a Refund.
  # At most one per member and Workshop (the active-member partial index).
  @open_attempt_statuses ~w(pending paid)

  # `pending` may go straight to a terminal status because Stripe can answer
  # the create call terminally — `succeeded` for an instant refund, `failed`
  # or `canceled` — and that answer is written in the same locked step as the
  # Stripe refund id; `processing` is only the "accepted, not yet settled"
  # answer. ADR 0027's `pending → processing → …` is the usual path, not the
  # only one.
  @refund_transitions %{
    "pending" => ~w(processing completed failed cancelled),
    "processing" => ~w(completed failed cancelled)
  }

  @refund_statuses ~w(pending processing completed failed cancelled)
  @terminal_refund_statuses @refund_statuses -- Map.keys(@refund_transitions)

  # Index names as the migrations created them, and the domain reason each
  # becomes. Anything else is a programming error and may raise.
  @unique_constraints %{
    PaymentAttempt => [
      {:stripe_payment_intent_id, "club_activity_payment_attempts_stripe_payment_intent_id_index",
       :payment_metadata_mismatch},
      {:stripe_checkout_session_id,
       "club_activity_payment_attempts_stripe_checkout_session_id_index",
       :payment_metadata_mismatch},
      {:member_user_id, "club_activity_payment_attempts_active_member_unique", :payment_failed},
      {:id, "club_activity_payment_attempts_pkey", :payment_failed}
    ],
    Registration => [
      {:payment_attempt_id, "club_activity_registrations_payment_attempt_id_index",
       :already_registered},
      {:stripe_payment_intent_id, "club_activity_registrations_stripe_payment_intent_id_unique",
       :already_registered},
      {:stripe_checkout_session_id,
       "club_activity_registrations_stripe_checkout_session_id_unique", :already_registered},
      {:member_user_id, "club_activity_registrations_member_user_id_active_unique",
       :already_registered},
      {:external_user_id, "club_activity_registrations_external_user_id_active_unique",
       :already_registered}
    ],
    Refund => [
      {:registration_id, "club_activity_refunds_registration_id_index", :already_requested},
      {:payment_attempt_id, "club_activity_refunds_payment_attempt_id_index", :already_requested},
      {:idempotency_key, "club_activity_refunds_idempotency_key_index", :already_requested},
      {:stripe_refund_id, "club_activity_refunds_stripe_refund_id_index", :already_requested}
    ]
  }

  @lock_levels [
    workshop: Workshop,
    attempt: PaymentAttempt,
    registration: Registration,
    refund: Refund
  ]

  @doc """
  Executes one Workshop payment command as `actor`.

  The actor is authorized for the command before any read. Returns the
  command's outcome or a domain reason; a race never surfaces as an
  exception.
  """
  @spec execute(actor(), command()) :: {:ok, term()} | {:error, term()}
  def execute(actor, command) do
    with :ok <- authorize(actor, command) do
      run(actor, command)
    end
  end

  @doc "Whether `from → to` is a legal status write for `schema` (the transition table)."
  @spec transition_allowed?(PaymentAttempt | Refund, String.t(), String.t()) :: boolean()
  def transition_allowed?(schema, from, to), do: to in Map.get(transitions(schema), from, [])

  @doc false
  # The index names `persist/1` translates; a test checks each one exists.
  @spec declared_unique_indexes() :: [String.t()]
  def declared_unique_indexes do
    for {_schema, constraints} <- @unique_constraints,
        {_field, name, _reason} <- constraints,
        do: name
  end

  # ── Authorization ───────────────────────────────────────────────

  defp command_name(command) when is_tuple(command), do: elem(command, 0)
  defp command_name(command) when is_atom(command), do: command

  # Only a coordinator's cancellation may refund (the Refunds record them as
  # requester); the system may cancel a Workshop that refunds nobody.
  defp authorize(
         {:coordinator, id},
         {:cancel_workshop, _workshop_id, _transition, _registrations}
       )
       when is_binary(id),
       do: :ok

  defp authorize(:system, {:cancel_workshop, _workshop_id, _transition, :keep}), do: :ok
  defp authorize(actor, command), do: authorize_name(actor, command_name(command))

  defp authorize_name({:member, id}, name) when is_binary(id) and name in @member_commands,
    do: :ok

  defp authorize_name(:external, name) when name in @external_commands, do: :ok
  defp authorize_name({:coordinator, id}, :request_refund) when is_binary(id), do: :ok
  defp authorize_name(:system, name) when name in @system_commands, do: :ok

  defp authorize_name(_actor, name)
       when name in @member_commands or name in @external_commands or
              name in @coordinator_commands or name in @system_commands,
       do: {:error, :forbidden}

  defp authorize_name(_actor, _name), do: {:error, :unknown_command}

  # ── Starting a payment ──────────────────────────────────────────

  defp run({:member, user_id}, {:start_member_payment, workshop_id, customer_id}) do
    with {:ok, {attempt, workshop}} <-
           transact(fn ->
             with_locked(
               %{
                 workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
                 attempt: active_member_attempt_query(workshop_id, user_id)
               },
               &open_member_attempt(&1, user_id)
             )
           end),
         {:ok, payment_intent} <- member_payment_intent(attempt, workshop, customer_id),
         :ok <-
           record_identifier(attempt, :stripe_payment_intent_id, Map.fetch!(payment_intent, "id")) do
      {:ok,
       %{
         client_secret: Map.fetch!(payment_intent, "client_secret"),
         payment_intent_id: Map.fetch!(payment_intent, "id")
       }}
    end
    |> start_result(~w(not_found not_published already_registered full invalid_amount)a)
  end

  defp run(
         :external,
         {:start_external_payment, workshop_id, payment_attempt_id, return_url}
       ) do
    with true <- String.contains?(return_url, "{CHECKOUT_SESSION_ID}") || :invalid_return_url,
         {:ok, {attempt, workshop}} <-
           transact(fn ->
             with_locked(
               %{
                 workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
                 attempt: from(pa in PaymentAttempt, where: pa.id == ^payment_attempt_id)
               },
               &open_external_attempt(&1, payment_attempt_id)
             )
           end),
         {:ok, session} <- external_checkout_session(attempt, workshop, return_url),
         :ok <- record_identifier(attempt, :stripe_checkout_session_id, Map.fetch!(session, "id")) do
      external_checkout_result(session)
    else
      :invalid_return_url -> {:error, :invalid_return_url}
      {:error, reason} -> {:error, reason}
    end
    |> start_result(
      ~w(not_found full invalid_return_url invalid_amount checkout_session_not_found)a
    )
  end

  # ── Concluding a payment ────────────────────────────────────────

  defp run({:member, user_id}, {:complete_member_payment, workshop_id, payment_intent_id}) do
    with {:ok, payment_intent} <- retrieve_payment_intent(payment_intent_id),
         :ok <- validate_member_payment_intent(payment_intent, workshop_id, user_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
            attempt: {:all, member_attempt_candidates(workshop_id, user_id, payment_intent_id)}
          },
          &conclude_member_payment(&1, user_id, payment_intent)
        )
      end)
      |> conclusion_result()
    end
  end

  defp run(:external, {:complete_external_payment, workshop_id, checkout_session_id}) do
    with {:ok, session} <- retrieve_checkout_session(checkout_session_id),
         :ok <- validate_external_checkout_session(session, workshop_id),
         {:ok, customer} <- external_checkout_customer(session),
         {:ok, attempt_id} <- metadata_attempt_id(session),
         {:ok, {:paid, attempt}} <-
           transact(fn ->
             with_locked(
               %{
                 workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
                 attempt: from(pa in PaymentAttempt, where: pa.id == ^attempt_id)
               },
               &record_external_payment(&1, session, customer.email)
             )
           end)
           |> rejected_as_error(),
         :ok <- set_receipt_email(session, customer.email) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
            attempt: required(from(pa in PaymentAttempt, where: pa.id == ^attempt.id))
          },
          &conclude_external_payment(&1, session, customer)
        )
      end)
      |> conclusion_result()
    end
  end

  # ── Cancelling and refunding Registrations ──────────────────────

  defp run({:member, user_id}, {:cancel_member_registration, workshop_id}) do
    transact(fn ->
      with_locked(
        %{
          workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
          registration:
            from(r in Registration,
              where:
                r.club_activity_id == ^workshop_id and r.member_user_id == ^user_id and
                  r.status in ^Registration.active_statuses(),
              limit: 1
            ),
          refund: &registration_refund_query/1
        },
        &cancel_member_registration(&1, user_id)
      )
    end)
  end

  defp run({:coordinator, requested_by}, {:request_refund, workshop_id, registration_id, reason}) do
    transact(fn ->
      with_locked(
        %{
          workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
          registration:
            from(r in Registration,
              where: r.id == ^registration_id and r.club_activity_id == ^workshop_id
            ),
          refund: &registration_refund_query/1
        },
        &request_registration_refund(&1, reason, requested_by)
      )
    end)
    |> case do
      {:error, :not_found} -> {:error, :registration_not_found}
      other -> other
    end
  end

  # Every Registration of the Workshop is locked; which of them are owed a
  # Refund is decided over the locked rows by RefundPolicy.owed_on_cancellation?/1.
  defp run(actor, {:cancel_workshop, workshop_id, transition_workshop, registrations}) do
    transact(fn ->
      with_locked(
        %{
          workshop: required(from(w in Workshop, where: w.id == ^workshop_id)),
          registration:
            if(registrations == :refund_owed,
              do: {:all, from(r in Registration, where: r.club_activity_id == ^workshop_id)}
            ),
          refund: &owed_refunds_query/1
        },
        &cancel_workshop(&1, transition_workshop, requester(actor))
      )
    end)
  end

  # ── Refund progression ──────────────────────────────────────────

  defp run(:system, {:submit_refund, refund_id}) do
    case with_locked_refund(from(r in Refund, where: r.id == ^refund_id), &submission_plan/1) do
      {:ok, :settled} -> {:ok, :settled}
      {:ok, {:submit, refund, source}} -> submit_refund(refund, source)
      {:error, :not_found} -> {:error, :refund_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(:system, {:apply_refund_update, %{"id" => stripe_refund_id, "status" => status}})
       when is_binary(stripe_refund_id) and is_binary(status) do
    from(r in Refund, where: r.stripe_refund_id == ^stripe_refund_id)
    |> with_locked_refund(&settle_refund(&1, status, %{}))
    |> case do
      {:error, :not_found} -> {:ok, :unknown_refund}
      other -> other
    end
  end

  defp run(:system, {:apply_refund_update, _object}), do: {:error, :invalid_refund_object}

  defp run(:system, :reconcile_refunds) do
    submissions =
      from(r in Refund, where: r.status == "pending", select: r.id)
      |> Repo.all()
      |> Enum.map(&enqueue_submission/1)

    provider_updates =
      from(r in Refund,
        where: r.status == "processing" and not is_nil(r.stripe_refund_id),
        select: r.stripe_refund_id
      )
      |> Repo.all()
      |> Enum.map(fn stripe_refund_id ->
        with {:ok, object} <- stripe_adapter().retrieve_refund(stripe_refund_id) do
          run(:system, {:apply_refund_update, object})
        end
      end)

    case Enum.find(submissions ++ provider_updates, &match?({:error, _reason}, &1)) do
      nil -> {:ok, :reconciled}
      error -> error
    end
  end

  defp run(_actor, _command), do: {:error, :unknown_command}

  # ── Command bodies (under the lock) ─────────────────────────────

  defp open_member_attempt(%{attempt: %PaymentAttempt{} = attempt, workshop: workshop}, _user_id),
    do: {:ok, {attempt, workshop}}

  defp open_member_attempt(%{workshop: workshop}, user_id) do
    with :ok <- member_registration_open(workshop),
         :ok <- no_active_registration(workshop.id, :member_user_id, user_id),
         :ok <- capacity_available(workshop),
         {:ok, amount} <- positive_amount(workshop.price_member),
         {:ok, attempt} <-
           persist(new_attempt(workshop, amount, "pending", member_user_id: user_id)) do
      {:ok, {attempt, workshop}}
    end
  end

  defp open_external_attempt(%{attempt: %PaymentAttempt{} = attempt, workshop: workshop}, _id) do
    if attempt.club_activity_id == workshop.id and attempt.actor_type == @external_actor_type,
      do: {:ok, {attempt, workshop}},
      else: {:error, :payment_failed}
  end

  defp open_external_attempt(%{workshop: workshop}, payment_attempt_id) do
    with :ok <- external_registration_open(workshop),
         :ok <- capacity_available(workshop),
         {:ok, amount} <- positive_amount(workshop.price_non_member),
         {:ok, attempt} <-
           persist(new_attempt(workshop, amount, "pending", id: payment_attempt_id)) do
      {:ok, {attempt, workshop}}
    end
  end

  defp conclude_member_payment(
         %{workshop: workshop, attempt: candidates},
         user_id,
         payment_intent
       ) do
    with {:ok, attempt} <- member_attempt(candidates, workshop, user_id, payment_intent) do
      if amount_matches?(attempt, payment_intent),
        do: register_member(workshop, attempt, user_id, payment_intent),
        else: fail_policy(attempt)
    end
  end

  # The PaymentIntent's own attempt wins; otherwise the member's open attempt
  # is recovered (Stripe succeeded before its id was persisted); otherwise a
  # paid attempt is recorded for the payment Stripe already took.
  defp member_attempt(candidates, workshop, user_id, payment_intent) do
    payment_intent_id = Map.fetch!(payment_intent, "id")
    owned = Enum.find(candidates, &(&1.stripe_payment_intent_id == payment_intent_id))
    open = Enum.find(candidates, &open_member_attempt?(&1, workshop.id, user_id))

    cond do
      owned && open_member_attempt?(owned, workshop.id, user_id, :any) ->
        {:ok, owned}

      owned ->
        {:error, :payment_metadata_mismatch}

      open && is_nil(open.stripe_payment_intent_id) ->
        transition(open, "paid", %{stripe_payment_intent_id: payment_intent_id, paid_at: now()})

      open ->
        {:error, :payment_metadata_mismatch}

      true ->
        record_paid_member_attempt(workshop, user_id, payment_intent_id)
    end
  end

  defp record_paid_member_attempt(workshop, user_id, payment_intent_id) do
    with {:ok, amount} <- positive_amount(workshop.price_member) do
      persist(
        new_attempt(workshop, amount, "paid",
          member_user_id: user_id,
          stripe_payment_intent_id: payment_intent_id,
          paid_at: now()
        )
      )
    end
  end

  # A member attempt carries `member_user_id`; an external one its
  # caller-chosen `id` (the Checkout metadata identity). Workshop payments are
  # always in euro.
  defp new_attempt(workshop, amount, status, attrs) do
    {id, attrs} = Keyword.pop(attrs, :id)
    actor_type = if attrs[:member_user_id], do: @member_actor_type, else: @external_actor_type

    Ecto.Changeset.change(
      %PaymentAttempt{id: id},
      Map.merge(Map.new(attrs), %{
        club_activity_id: workshop.id,
        actor_type: actor_type,
        amount: amount,
        currency: "eur",
        status: status
      })
    )
  end

  defp open_member_attempt?(attempt, workshop_id, user_id, statuses \\ @open_attempt_statuses) do
    attempt.club_activity_id == workshop_id and attempt.member_user_id == user_id and
      attempt.actor_type == @member_actor_type and
      (statuses == :any or attempt.status in statuses)
  end

  defp register_member(workshop, attempt, user_id, payment_intent) do
    payment_intent_id = Map.fetch!(payment_intent, "id")

    case concluded(attempt, stripe_payment_intent_id: payment_intent_id) do
      {:registered, registration} ->
        {:ok, {:registered, registration}}

      :compensating ->
        {:ok, :compensation_pending}

      :open ->
        with {:ok, attempt} <- ensure_paid(attempt) do
          register_paid_member(workshop, attempt, user_id, payment_intent)
        end
    end
  end

  defp register_paid_member(workshop, attempt, user_id, payment_intent) do
    with :ok <- member_registration_open(workshop),
         :ok <- no_active_registration(workshop.id, :member_user_id, user_id),
         :ok <- capacity_available(workshop),
         {:ok, registration} <-
           persist(member_registration_changeset(workshop, attempt, user_id, payment_intent),
             recoverable: true
           ),
         {:ok, _attempt} <- conclude_registered(attempt) do
      {:ok, {:registered, registration}}
    else
      {:error, :full} ->
        compensate(attempt, "Workshop capacity exhausted")

      {:error, reason} when reason in [:not_found, :not_published] ->
        compensate(attempt, "Workshop unavailable")

      # The member holds another active Registration: the attempt stays paid
      # and the outcome is reported, as before.
      {:error, :already_registered} ->
        {:ok, {:rejected, :already_registered}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_external_payment(%{workshop: workshop, attempt: attempt}, session, email) do
    checkout_session_id = Map.fetch!(session, "id")

    with {:ok, attempt} <- external_attempt(attempt, workshop, checkout_session_id),
         {:ok, attempt} <- mark_external_paid(attempt, checkout_session_id, email) do
      if amount_matches?(attempt, session),
        do: {:ok, {:paid, attempt}},
        else: fail_policy(attempt)
    end
  end

  defp external_attempt(
         %PaymentAttempt{actor_type: @external_actor_type, stripe_checkout_session_id: stored} =
           attempt,
         %Workshop{id: workshop_id},
         checkout_session_id
       )
       when attempt.club_activity_id == workshop_id and
              (is_nil(stored) or stored == checkout_session_id),
       do: {:ok, attempt}

  defp external_attempt(_attempt, _workshop, _checkout_session_id),
    do: {:error, :payment_metadata_mismatch}

  defp mark_external_paid(%PaymentAttempt{status: status} = attempt, checkout_session_id, email)
       when status in @open_attempt_statuses do
    transition(attempt, "paid", %{
      external_email: email,
      stripe_checkout_session_id: checkout_session_id,
      paid_at: attempt.paid_at || now()
    })
  end

  defp mark_external_paid(attempt, _checkout_session_id, _email), do: {:ok, attempt}

  defp conclude_external_payment(%{workshop: workshop, attempt: attempt}, session, customer) do
    checkout_session_id = Map.fetch!(session, "id")
    payment_intent_id = Map.get(session, "payment_intent")

    case concluded(attempt, stripe_checkout_session_id: checkout_session_id) do
      {:registered, registration} ->
        {:ok, {:registered, registration}}

      :compensating ->
        {:ok, :compensation_pending}

      :open ->
        with {:ok, attempt} <- ensure_paid(attempt) do
          register_external(workshop, attempt, customer, payment_intent_id)
        end
    end
  end

  defp register_external(workshop, attempt, customer, payment_intent_id) do
    with :ok <- external_registration_open(workshop),
         {:ok, external_user} <- upsert_external_user(customer),
         :ok <- no_active_registration(workshop.id, :external_user_id, external_user.id),
         :ok <- capacity_available(workshop),
         {:ok, registration} <-
           persist(external_registration_changeset(workshop, attempt, external_user, customer),
             recoverable: true
           ),
         {:ok, _attempt} <- conclude_registered(attempt) do
      {:ok, {:registered, registration}}
    else
      {:error, reason} when reason in [:not_found, :already_registered, :full] ->
        compensate(attempt, external_compensation_reason(reason), payment_intent_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp external_compensation_reason(:already_registered), do: "Attendee already registered"
  defp external_compensation_reason(:full), do: "Workshop capacity exhausted"
  defp external_compensation_reason(:not_found), do: "Workshop unavailable"

  # A Payment Attempt concludes exactly once: with its Registration, or with
  # the compensating Refund recorded against it.
  defp concluded(attempt, [{identifier, value}]) do
    registration =
      Repo.get_by(Registration, payment_attempt_id: attempt.id) ||
        Repo.get_by(Registration, [{identifier, value}])

    cond do
      registration ->
        {:registered, registration}

      Repo.exists?(from(rf in Refund, where: rf.payment_attempt_id == ^attempt.id)) ->
        :compensating

      true ->
        :open
    end
  end

  defp ensure_paid(%PaymentAttempt{status: "pending"} = attempt),
    do: transition(attempt, "paid", %{paid_at: attempt.paid_at || now()})

  defp ensure_paid(%PaymentAttempt{status: "paid"} = attempt), do: {:ok, attempt}
  defp ensure_paid(%PaymentAttempt{}), do: {:error, :payment_metadata_mismatch}

  defp conclude_registered(attempt) do
    now = now()
    transition(attempt, "registered", %{paid_at: attempt.paid_at || now, concluded_at: now})
  end

  defp fail_policy(attempt) do
    if transition_allowed?(PaymentAttempt, attempt.status, "policy_failed") do
      with {:ok, _attempt} <- transition(attempt, "policy_failed", %{}) do
        {:ok, {:rejected, :payment_metadata_mismatch}}
      end
    else
      {:ok, {:rejected, :payment_metadata_mismatch}}
    end
  end

  defp compensate(attempt, reason, payment_intent_id \\ nil) do
    now = now()

    refund =
      new_refund(%{
        payment_attempt_id: attempt.id,
        refund_amount: attempt.amount,
        refund_reason: reason,
        stripe_payment_intent_id: payment_intent_id || attempt.stripe_payment_intent_id
      })

    with {:ok, refund} <- persist(refund),
         :ok <- enqueue_submission(refund.id),
         {:ok, _attempt} <-
           transition(attempt, "compensating", %{
             paid_at: attempt.paid_at || now,
             concluded_at: now
           }) do
      {:ok, :compensation_pending}
    end
  end

  defp cancel_member_registration(%{registration: nil}, _user_id), do: {:error, :not_found}

  defp cancel_member_registration(
         %{workshop: workshop, registration: registration} = locked,
         user_id
       ) do
    facts = refund_facts(workshop, registration, locked.refund)

    case RefundPolicy.requested_refund(facts, DateTime.utc_now()) do
      :ok ->
        with {:ok, refund, refunded} <-
               record_registration_refund(registration, "Member cancelled registration", user_id) do
          {:ok, %{registration: refunded, refund_pending: refund.status == "pending"}}
        end

      {:error, _ineligible} ->
        with {:ok, cancelled} <-
               persist(
                 Ecto.Changeset.change(registration, status: "cancelled", cancelled_at: now())
               ) do
          {:ok, %{registration: cancelled, refund_pending: false}}
        end
    end
  end

  defp request_registration_refund(%{registration: nil}, _reason, _requested_by),
    do: {:error, :registration_not_found}

  defp request_registration_refund(locked, reason, requested_by) do
    %{workshop: workshop, registration: registration, refund: refund} = locked
    facts = refund_facts(workshop, registration, refund)

    with :ok <- RefundPolicy.requested_refund(facts, DateTime.utc_now()),
         {:ok, refund, refunded} <- record_registration_refund(registration, reason, requested_by) do
      {:ok, %{refund: refund, view: RefundProjection.project(refund, refunded)}}
    end
  end

  defp cancel_workshop(%{workshop: workshop} = locked, transition_workshop, requested_by) do
    with {:ok, cancelled} <- transition_workshop.(workshop),
         :ok <- refund_cancelled_registrations(locked, requested_by) do
      {:ok, cancelled}
    end
  end

  defp refund_cancelled_registrations(%{registration: nil}, _requested_by), do: :ok

  defp refund_cancelled_registrations(%{workshop: workshop} = locked, requested_by) do
    refunded_ids = MapSet.new(locked.refund || [], & &1.registration_id)

    locked.registration
    |> Enum.filter(&RefundPolicy.owed_on_cancellation?/1)
    |> Enum.reduce_while(:ok, fn registration, :ok ->
      facts = %{
        registration: registration,
        workshop: workshop,
        refund_requested?: MapSet.member?(refunded_ids, registration.id)
      }

      # A Registration whose Refund is already recorded is skipped. A unique
      # violation on the insert (a Refund written outside this seam) aborts
      # the whole cancellation with `:already_requested` instead of raising.
      with :ok <- RefundPolicy.cancellation_refund(facts),
           {:ok, _refund, _registration} <-
             record_registration_refund(registration, "Workshop cancelled", requested_by) do
        {:cont, :ok}
      else
        {:error, :already_requested} when facts.refund_requested? -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp refund_facts(workshop, registration, refund) do
    %{registration: registration, workshop: workshop, refund_requested?: not is_nil(refund)}
  end

  # Creates the durable repayment obligation and its submission job, and
  # marks the Registration refunded — one transaction, under its lock.
  defp record_registration_refund(registration, reason, requested_by) do
    refund =
      new_refund(%{
        registration_id: registration.id,
        refund_amount: registration.amount_paid,
        refund_reason: reason,
        requested_by: requested_by,
        stripe_payment_intent_id: registration.stripe_payment_intent_id
      })

    with {:ok, refund} <- persist(refund),
         :ok <- enqueue_submission(refund.id),
         {:ok, refunded} <- persist(Ecto.Changeset.change(registration, status: "refunded")) do
      {:ok, refund, refunded}
    end
  end

  defp new_refund(attrs) do
    id = Ecto.UUID.generate()

    Ecto.Changeset.change(
      %Refund{id: id},
      Map.merge(attrs, %{
        status: "pending",
        idempotency_key: "workshop-refund:#{id}",
        requested_at: now()
      })
    )
  end

  defp enqueue_submission(refund_id) do
    case %{refund_id: refund_id} |> RefundWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Refund submission (Stripe between two locked reads) ─────────

  defp submission_plan(%{refund: %Refund{status: status}})
       when status in @terminal_refund_statuses,
       do: {:ok, :settled}

  defp submission_plan(%{refund: %Refund{status: "processing", stripe_refund_id: id}})
       when is_binary(id),
       do: {:ok, :settled}

  defp submission_plan(%{refund: refund} = locked),
    do: {:ok, {:submit, refund, payment_intent_source(refund, locked)}}

  defp payment_intent_source(%Refund{stripe_payment_intent_id: id}, _locked)
       when is_binary(id) and id != "",
       do: {:payment_intent, id}

  defp payment_intent_source(_refund, %{registration: %Registration{} = registration}),
    do: stripe_source(registration)

  defp payment_intent_source(_refund, %{attempt: %PaymentAttempt{} = attempt}),
    do: stripe_source(attempt)

  defp payment_intent_source(_refund, _locked), do: :unresolvable

  defp stripe_source(%{stripe_payment_intent_id: id}) when is_binary(id) and id != "",
    do: {:payment_intent, id}

  defp stripe_source(%{stripe_checkout_session_id: id}) when is_binary(id) and id != "",
    do: {:checkout_session, id}

  defp stripe_source(_row), do: :unresolvable

  defp submit_refund(refund, source) do
    with {:ok, payment_intent_id} <- resolve_payment_intent(source),
         {:ok, response} <-
           stripe_adapter().create_refund(%{
             body: [
               payment_intent: payment_intent_id,
               amount: refund.refund_amount,
               reason: "requested_by_customer"
             ],
             idempotency_key: refund.idempotency_key
           }) do
      record_submission(refund.id, payment_intent_id, response)
    else
      {:error, {:stripe_api, status, _body} = reason}
      when status in 400..499 and status not in [408, 409, 429] ->
        record_intervention(refund.id, reason)

      {:error, :payment_intent_not_resolvable = reason} ->
        record_intervention(refund.id, reason)

      {:error, reason} ->
        record_retryable_error(refund.id, reason)
    end
  end

  defp resolve_payment_intent({:payment_intent, id}), do: {:ok, id}
  defp resolve_payment_intent(:unresolvable), do: {:error, :payment_intent_not_resolvable}

  defp resolve_payment_intent({:checkout_session, id}) do
    case stripe_adapter().retrieve_checkout_session(id) do
      {:ok, %{"payment_intent" => payment_intent_id}}
      when is_binary(payment_intent_id) and payment_intent_id != "" ->
        {:ok, payment_intent_id}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :payment_intent_not_resolvable}
    end
  end

  defp record_submission(refund_id, payment_intent_id, response) do
    provider_status = Map.get(response, "status", "pending")

    with {:ok, _refund} <-
           with_locked_refund(from(r in Refund, where: r.id == ^refund_id), fn locked ->
             settle_refund(locked, provider_status, %{
               stripe_refund_id: Map.fetch!(response, "id"),
               stripe_payment_intent_id: payment_intent_id,
               processed_at: locked.refund.processed_at || now()
             })
           end) do
      {:ok, :submitted}
    end
  end

  defp record_intervention(refund_id, reason) do
    with {:ok, _refund} <-
           with_locked_refund(from(r in Refund, where: r.id == ^refund_id), fn %{refund: refund} ->
             ignore_settled(
               transition(refund, "failed", %{last_error: error_text(reason)}),
               refund
             )
           end) do
      {:error, {:intervention_required, reason}}
    end
  end

  defp record_retryable_error(refund_id, reason) do
    _ =
      with_locked_refund(from(r in Refund, where: r.id == ^refund_id), fn
        %{refund: %Refund{status: "pending"} = refund} ->
          transition(refund, "pending", %{last_error: error_text(reason)})

        %{refund: refund} ->
          {:ok, refund}
      end)

    {:error, reason}
  end

  # Writes a Stripe refund status through the transition table. A Refund
  # already in a terminal status keeps it, so a late event or a stale
  # submission result is acknowledged and ignored.
  defp settle_refund(%{refund: refund} = locked, provider_status, attrs) do
    status = local_refund_status(provider_status)

    attrs =
      Map.merge(attrs, %{
        provider_status: provider_status,
        completed_at: if(status == "completed", do: refund.completed_at || now()),
        last_error: if(status == "failed", do: "Stripe refund failed")
      })

    with {:ok, settled} <- ignore_settled(transition(refund, status, attrs), refund),
         :ok <- conclude_compensation(settled, locked.attempt) do
      {:ok, settled}
    end
  end

  defp local_refund_status("succeeded"), do: "completed"
  defp local_refund_status("failed"), do: "failed"
  defp local_refund_status("canceled"), do: "cancelled"
  defp local_refund_status(_pending_or_requires_action), do: "processing"

  defp conclude_compensation(
         %Refund{status: "completed"},
         %PaymentAttempt{status: "compensating"} = attempt
       ) do
    with {:ok, _attempt} <- transition(attempt, "refunded", %{concluded_at: now()}), do: :ok
  end

  defp conclude_compensation(_refund, _attempt), do: :ok

  defp ignore_settled({:error, {:illegal_transition, _from, _to}}, row), do: {:ok, row}
  defp ignore_settled(result, _row), do: result

  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 2_000)

  # ── The locking primitive ───────────────────────────────────────

  # `spec` names the rows to lock per level; levels are always taken in
  # `@lock_levels` order. A level's spec is `nil` (skip), a query (zero or one
  # row), `{:all, query}` (rows, in id order), `{:required, query}` (one row
  # or `:not_found`), or a function of the rows locked so far returning one
  # of those. Must run inside `transact/1`.
  defp with_locked(spec, fun) do
    @lock_levels
    |> Enum.reduce_while({:ok, %{}}, fn {level, schema}, {:ok, locked} ->
      case spec |> Map.get(level) |> resolve_spec(locked) |> lock_rows(schema) do
        {:ok, rows} -> {:cont, {:ok, Map.put(locked, level, rows)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, locked} -> fun.(locked)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_spec(spec, locked) when is_function(spec, 1), do: spec.(locked)
  defp resolve_spec(spec, _locked), do: spec

  defp lock_rows(nil, _schema), do: {:ok, nil}

  defp lock_rows({:all, query}, _schema),
    do:
      {:ok,
       query
       |> exclude(:order_by)
       |> order_by([row], asc: row.id)
       |> lock("FOR UPDATE")
       |> Repo.all()}

  defp lock_rows({:required, query}, schema) do
    case lock_rows(query, schema) do
      {:ok, nil} -> {:error, :not_found}
      found -> found
    end
  end

  defp lock_rows(%Ecto.Query{} = query, _schema),
    do: {:ok, query |> lock("FOR UPDATE") |> Repo.one()}

  defp required(query), do: {:required, query}

  # Commands that begin from a Refund: peek it unlocked to learn what it
  # points to, lock those rows in order, re-read the Refund under the lock,
  # and start over from a fresh peek if it no longer points there.
  defp with_locked_refund(query, fun), do: with_locked_refund(query, fun, @refund_peek_attempts)

  defp with_locked_refund(_query, _fun, 0), do: {:error, :retry_exhausted}

  defp with_locked_refund(query, fun, attempts_left) do
    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %Refund{} = peeked ->
        case lock_peeked_refund(peeked, fun) do
          {:error, :refund_moved} -> with_locked_refund(query, fun, attempts_left - 1)
          other -> other
        end
    end
  end

  defp lock_peeked_refund(peeked, fun) do
    transact(fn ->
      with_locked(
        %{
          attempt: by_id(PaymentAttempt, peeked.payment_attempt_id),
          registration: by_id(Registration, peeked.registration_id),
          refund: required(from(r in Refund, where: r.id == ^peeked.id))
        },
        &unless_moved(peeked, &1, fun)
      )
    end)
  end

  defp unless_moved(peeked, %{refund: refund} = locked, fun) do
    if moved?(peeked, refund), do: {:error, :refund_moved}, else: fun.(locked)
  end

  defp by_id(_schema, nil), do: nil
  defp by_id(schema, id), do: from(row in schema, where: row.id == ^id)

  defp moved?(peeked, refund) do
    peeked.payment_attempt_id != refund.payment_attempt_id or
      peeked.registration_id != refund.registration_id
  end

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, outcome} -> outcome
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ── Transition table and write path ─────────────────────────────

  defp transitions(PaymentAttempt), do: @attempt_transitions
  defp transitions(Refund), do: @refund_transitions

  defp transition(%schema{status: status} = row, to, attrs) do
    cond do
      to == status and Map.has_key?(transitions(schema), status) ->
        persist(Ecto.Changeset.change(row, attrs))

      transition_allowed?(schema, status, to) ->
        persist(Ecto.Changeset.change(row, Map.put(attrs, :status, to)))

      true ->
        {:error, {:illegal_transition, status, to}}
    end
  end

  # A unique violation aborts the whole Postgres transaction, so a command may
  # only *continue* after a translated violation if the write ran under a
  # savepoint: pass `recoverable: true` for exactly those writes (the
  # Registration inserts whose violation becomes a rejection or a
  # compensating Refund). Every other translated violation rolls the
  # command's transaction back.
  defp persist(%Ecto.Changeset{data: %schema{}} = changeset, opts \\ []) do
    repo_opts = if Keyword.get(opts, :recoverable, false), do: [mode: :savepoint], else: []

    changeset
    |> declare_unique_constraints(schema)
    |> insert_or_update(repo_opts)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{} = failed} -> {:error, constraint_reason(failed, schema)}
    end
  end

  defp insert_or_update(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset, opts),
    do: Repo.insert(changeset, opts)

  defp insert_or_update(changeset, opts), do: Repo.update(changeset, opts)

  defp declare_unique_constraints(changeset, schema) do
    @unique_constraints
    |> Map.get(schema, [])
    |> Enum.reduce(changeset, fn {field, name, _reason}, acc ->
      Ecto.Changeset.unique_constraint(acc, field, name: name)
    end)
  end

  defp constraint_reason(%Ecto.Changeset{errors: errors}, schema) do
    reasons = Map.new(Map.get(@unique_constraints, schema, []), fn {_f, name, r} -> {name, r} end)

    Enum.find_value(errors, :constraint_violation, fn {_field, {_message, meta}} ->
      Map.get(reasons, to_string(Keyword.get(meta, :constraint_name)))
    end)
  end

  # Write two of starting a payment: record the provider object's id on the
  # attempt after the Stripe call, under the attempt lock.
  defp record_identifier(%PaymentAttempt{} = attempt, field, value) do
    if Map.fetch!(attempt, field) == value do
      :ok
    else
      transact(fn ->
        with_locked(
          %{attempt: required(from(pa in PaymentAttempt, where: pa.id == ^attempt.id))},
          &write_identifier(&1.attempt, field, value)
        )
      end)
      |> case do
        {:ok, _attempt} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_identifier(attempt, field, value) do
    case Map.fetch!(attempt, field) do
      ^value -> {:ok, attempt}
      nil -> persist(Ecto.Changeset.change(attempt, [{field, value}]))
      _other -> {:error, :payment_failed}
    end
  end

  # ── Results ─────────────────────────────────────────────────────

  defp conclusion_result({:ok, {:registered, registration}}), do: {:ok, registration}
  defp conclusion_result({:ok, :compensation_pending}), do: {:error, :compensation_pending}
  defp conclusion_result({:ok, {:rejected, reason}}), do: {:error, reason}
  defp conclusion_result({:error, reason}), do: {:error, reason}

  defp rejected_as_error({:ok, {:rejected, reason}}), do: {:error, reason}
  defp rejected_as_error(result), do: result

  # Starting a payment reports only the reasons its public function declares;
  # any other failure — a provider error or a translated race — is a payment
  # failure.
  defp start_result({:ok, result}, _known), do: {:ok, result}

  defp start_result({:error, reason}, known),
    do: {:error, if(reason in known, do: reason, else: :payment_failed)}

  defp external_checkout_result(session) do
    case Map.get(session, "client_secret") do
      secret when is_binary(secret) and secret != "" ->
        {:ok,
         %{
           checkout_session_id: Map.fetch!(session, "id"),
           checkout_client_secret: secret,
           checkout_url: Map.get(session, "url")
         }}

      _missing ->
        {:error, :payment_failed}
    end
  end

  # ── Gates (evaluated under the Workshop lock) ───────────────────

  defp member_registration_open(%Workshop{archived_at: %DateTime{}}), do: {:error, :not_found}

  defp member_registration_open(%Workshop{status: status}) when status != "published",
    do: {:error, :not_published}

  defp member_registration_open(%Workshop{}), do: :ok

  defp external_registration_open(%Workshop{
         status: "published",
         archived_at: nil,
         is_public: true,
         price_non_member: price
       })
       when not is_nil(price) and price >= 0,
       do: :ok

  defp external_registration_open(_workshop), do: {:error, :not_found}

  defp no_active_registration(workshop_id, participant_field, participant_id) do
    from(r in Registration,
      where:
        r.club_activity_id == ^workshop_id and field(r, ^participant_field) == ^participant_id and
          r.status in ^Registration.active_statuses()
    )
    |> Repo.exists?()
    |> if(do: {:error, :already_registered}, else: :ok)
  end

  defp capacity_available(%Workshop{id: id, max_capacity: max_capacity}) do
    count =
      from(r in Registration,
        where: r.club_activity_id == ^id and r.status in ^Registration.active_statuses(),
        select: count(r.id)
      )
      |> Repo.one()

    if count >= max_capacity, do: {:error, :full}, else: :ok
  end

  defp positive_amount(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_amount(value) when is_float(value) and value > 0, do: {:ok, trunc(value)}

  defp positive_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {amount, ""} when amount > 0 -> {:ok, amount}
      _invalid -> {:error, :invalid_amount}
    end
  end

  defp positive_amount(_value), do: {:error, :invalid_amount}

  defp amount_matches?(attempt, provider_object) do
    amount = Map.get(provider_object, "amount") || Map.get(provider_object, "amount_total")
    currency = provider_object |> Map.get("currency", "") |> String.downcase()
    amount == attempt.amount and currency == attempt.currency
  end

  # ── Queries ─────────────────────────────────────────────────────

  defp active_member_attempt_query(workshop_id, user_id) do
    from(pa in PaymentAttempt,
      where:
        pa.club_activity_id == ^workshop_id and pa.member_user_id == ^user_id and
          pa.actor_type == @member_actor_type and pa.status in @open_attempt_statuses
    )
  end

  defp member_attempt_candidates(workshop_id, user_id, payment_intent_id) do
    from(pa in PaymentAttempt,
      where:
        pa.stripe_payment_intent_id == ^payment_intent_id or
          (pa.club_activity_id == ^workshop_id and pa.member_user_id == ^user_id and
             pa.actor_type == @member_actor_type and pa.status in @open_attempt_statuses)
    )
  end

  defp registration_refund_query(%{registration: %Registration{id: id}}),
    do: from(rf in Refund, where: rf.registration_id == ^id)

  defp registration_refund_query(_locked), do: nil

  defp owed_refunds_query(%{registration: [_ | _] = registrations}) do
    ids = for r <- registrations, RefundPolicy.owed_on_cancellation?(r), do: r.id
    {:all, from(rf in Refund, where: rf.registration_id in ^ids)}
  end

  defp owed_refunds_query(_locked), do: nil

  defp requester({:coordinator, id}), do: id
  defp requester(:system), do: nil

  # ── Registration rows ───────────────────────────────────────────

  defp member_registration_changeset(workshop, attempt, user_id, payment_intent) do
    now = now()
    # ALE-181: the attendee snapshot is captured at write time.
    {display_name, email} = member_snapshot(user_id)

    Ecto.Changeset.change(%Registration{}, %{
      club_activity_id: workshop.id,
      member_user_id: user_id,
      display_name: display_name,
      email: email,
      status: "confirmed",
      stripe_payment_intent_id: Map.fetch!(payment_intent, "id"),
      payment_attempt_id: attempt.id,
      amount_paid: Map.get(payment_intent, "amount"),
      currency: Map.get(payment_intent, "currency", "eur"),
      confirmed_at: now,
      registered_at: now
    })
  end

  defp external_registration_changeset(workshop, attempt, external_user, customer) do
    now = now()

    Ecto.Changeset.change(%Registration{}, %{
      club_activity_id: workshop.id,
      external_user_id: external_user.id,
      display_name: Registration.display_name(customer.first_name, customer.last_name),
      email: customer.email,
      status: "confirmed",
      stripe_checkout_session_id: attempt.stripe_checkout_session_id,
      payment_attempt_id: attempt.id,
      amount_paid: attempt.amount,
      currency: attempt.currency,
      confirmed_at: now,
      registered_at: now
    })
  end

  # ALE-181: a missing profile resolves to the sentinel with no email, so a
  # registration never fails on a dangling member id.
  defp member_snapshot(principal_id) do
    from(up in UserProfile,
      left_join: p in Principal,
      on: p.id == up.principal_id,
      where: up.principal_id == ^principal_id,
      select: %{first_name: up.first_name, last_name: up.last_name, email: p.email}
    )
    |> Repo.one()
    |> case do
      nil ->
        {Registration.unknown_member(), nil}

      %{first_name: first, last_name: last, email: email} ->
        {Registration.display_name(first, last), email}
    end
  end

  # The external attendee is identity, not payment state: an upsert by email
  # outside the transition table, inside the conclusion's transaction.
  defp upsert_external_user(customer) do
    %ExternalUser{
      email: customer.email,
      first_name: customer.first_name,
      last_name: customer.last_name,
      phone_number: customer.phone_number
    }
    |> Repo.insert(
      on_conflict: [
        set: [
          first_name: customer.first_name,
          last_name: customer.last_name,
          phone_number: customer.phone_number,
          updated_at: now()
        ]
      ],
      conflict_target: :email,
      returning: true
    )
  end

  # ── Stripe (never inside a transaction) ─────────────────────────

  defp member_payment_intent(%PaymentAttempt{stripe_payment_intent_id: id}, _workshop, _customer)
       when is_binary(id) do
    case stripe_adapter().retrieve_payment_intent(id) do
      {:ok, %{"id" => ^id, "client_secret" => secret} = payment_intent} when is_binary(secret) ->
        {:ok, payment_intent}

      _failure ->
        {:error, :payment_failed}
    end
  end

  defp member_payment_intent(attempt, workshop, customer_id) do
    %{
      amount: attempt.amount,
      currency: attempt.currency,
      customer_id: customer_id,
      workshop_id: workshop.id,
      workshop_title: workshop.title,
      user_id: attempt.member_user_id,
      idempotency_key: "workshop-payment-attempt:#{attempt.id}"
    }
    |> stripe_adapter().create_payment_intent()
    |> case do
      {:ok, %{"id" => id, "client_secret" => secret} = payment_intent}
      when is_binary(id) and is_binary(secret) ->
        {:ok, payment_intent}

      _failure ->
        {:error, :payment_failed}
    end
  end

  defp external_checkout_session(%PaymentAttempt{stripe_checkout_session_id: id}, _workshop, _url)
       when is_binary(id),
       do: retrieve_checkout_session(id)

  defp external_checkout_session(attempt, workshop, return_url) do
    body = [
      mode: "payment",
      ui_mode: "embedded",
      return_url: return_url,
      customer_creation: "if_required",
      "name_collection[individual][enabled]": "true",
      "name_collection[individual][optional]": "false",
      "invoice_creation[enabled]": "true",
      "payment_method_types[]": "card",
      "payment_method_types[]": "link",
      "payment_method_types[]": "sepa_debit",
      "phone_number_collection[enabled]": "true",
      "line_items[0][quantity]": 1,
      "line_items[0][price_data][currency]": "eur",
      "line_items[0][price_data][unit_amount]": attempt.amount,
      "line_items[0][price_data][product_data][name]": workshop.title,
      "metadata[type]": @workshop_registration_metadata_type,
      "metadata[actor_type]": @external_actor_type,
      "metadata[workshop_id]": workshop.id,
      "metadata[payment_attempt_id]": attempt.id
    ]

    case stripe_adapter().create_checkout_session(%{
           body: body,
           idempotency_key: "workshop-payment-attempt:#{attempt.id}"
         }) do
      {:ok, %{"id" => id} = session} when is_binary(id) -> {:ok, session}
      _failure -> {:error, :payment_failed}
    end
  end

  defp retrieve_checkout_session(checkout_session_id) do
    case stripe_adapter().retrieve_checkout_session(checkout_session_id) do
      {:ok, %{"id" => _id} = session} -> {:ok, session}
      _failure -> {:error, :checkout_session_not_found}
    end
  end

  defp retrieve_payment_intent(payment_intent_id) do
    case stripe_adapter().retrieve_payment_intent(payment_intent_id) do
      {:ok, %{"id" => _id} = payment_intent} -> {:ok, payment_intent}
      _failure -> {:error, :payment_failed}
    end
  end

  defp set_receipt_email(session, email) do
    case Map.get(session, "payment_intent") do
      payment_intent_id when is_binary(payment_intent_id) ->
        _ = stripe_adapter().update_payment_intent(payment_intent_id, receipt_email: email)
        :ok

      _none ->
        :ok
    end
  end

  defp validate_member_payment_intent(payment_intent, workshop_id, user_id) do
    metadata = Map.get(payment_intent, "metadata", %{}) || %{}

    cond do
      Map.get(payment_intent, "status") != "succeeded" ->
        {:error, :payment_not_completed}

      metadata["type"] != @workshop_registration_metadata_type or
        metadata["actor_type"] != @member_actor_type or
        metadata["workshop_id"] != workshop_id or metadata["user_id"] != user_id ->
        {:error, :payment_metadata_mismatch}

      true ->
        :ok
    end
  end

  defp validate_external_checkout_session(session, workshop_id) do
    metadata = Map.get(session, "metadata", %{}) || %{}

    cond do
      Map.get(session, "status") != "complete" or Map.get(session, "payment_status") != "paid" ->
        {:error, :payment_not_completed}

      metadata["type"] != @workshop_registration_metadata_type or
        metadata["actor_type"] != @external_actor_type or
          metadata["workshop_id"] != workshop_id ->
        {:error, :payment_metadata_mismatch}

      not is_integer(Map.get(session, "amount_total")) ->
        {:error, :payment_metadata_mismatch}

      true ->
        :ok
    end
  end

  defp metadata_attempt_id(session) do
    with %{"payment_attempt_id" => id} when is_binary(id) <-
           Map.get(session, "metadata", %{}) || %{},
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, id}
    else
      _missing -> {:error, :payment_metadata_mismatch}
    end
  end

  defp external_checkout_customer(session) do
    details = Map.get(session, "customer_details", %{}) || %{}

    email =
      (Map.get(details, "email") || Map.get(session, "customer_email") || "") |> String.trim()

    name = (Map.get(details, "name") || "") |> String.trim()

    case String.split(name, ~r/\s+/, parts: 2) do
      [first_name | rest] when email != "" and first_name != "" ->
        {:ok,
         %{
           email: String.downcase(email),
           first_name: first_name,
           last_name: Enum.at(rest, 0, ""),
           phone_number: Map.get(details, "phone")
         }}

      _missing ->
        {:error, :customer_details_missing}
    end
  end

  defp stripe_adapter, do: Application.fetch_env!(:dhc, :workshop_stripe_adapter)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
