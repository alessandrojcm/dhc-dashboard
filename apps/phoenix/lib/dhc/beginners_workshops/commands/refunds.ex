defmodule Dhc.BeginnersWorkshops.Commands.Refunds do
  @moduledoc """
  The refund commands (ALE-382, ALE-389, ALE-405): `submit_refund` and
  `reconcile` (`:system`), `apply_refund_event` (`:stripe`), and the
  follow-ups `retry_refund`, `record_manual_refund` and
  `forfeit_carried_fee` (`beginners.workshops.manage`). It owns
  `insert_refund/4`, the one refund-row writer, and the refund job.
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.

  ## Refunds (ALE-382)

  A refund is always the full amount the payment row took, against that
  payment's PaymentIntent, under the idempotency key
  `beginners-intake-refund:<id>` (`IntakeRefunds`, the only Stripe refund
  caller). An automatic refund is requested inside the transaction that
  discovers it is owed — a `policy_failed` payment or a completion after
  the Intake closed — which also enqueues its submission and queues
  "Payment refunded (automatic)". A refund that starts a command peeks the
  row (its payment never changes), then locks payment → refund; refund
  progression never takes the workshop or Intake lock.

    * `submit_refund` (`:system`, the refund worker) calls Stripe between
      transactions and writes the answer after a locked re-read. A Stripe
      outage leaves it `pending` and fails (the job retries); a refusal
      makes it `failed`.
    * `apply_refund_event` (`:stripe`, `refund.*`) finds the row by Stripe
      refund id, or by the refund id in the object's metadata when the event
      beat the submission's record. Any other refund is acknowledged as not
      ours (the Workshops target owns it).
    * `reconcile` (`:system`, the reconcile worker) repairs missed events in
      one bounded pass: pending refunds are enqueued again, processing ones
      re-read from Stripe, and live or releasing payment rows settled when
      their Checkout Session completed or expired.
    * `retry_refund` and `record_manual_refund` (`beginners.workshops.manage`)
      follow up a failed refund with a new row (`follows_refund_id`); the
      failed row stays as history and a refund is followed up once.

  Failed refunds ignore later events. A Stripe-completed refund can still
  fail asynchronously; manual completions and stale events remain settled. When a refund
  fails, the coordinator-alert holders get a keyed Notification
  (`beginners-workshop-refund:<id>:failed`, signalled after commit). Neither
  a failed refund nor a manual refund record emails the person.

  ## Carried Fee refunds (ALE-389)

  A Carried Fee refund is always the full amount originally paid, against
  the original payment, written by the one `insert_refund/4` with
  `carried_fee_id` set: a deferral's fee against its Intake payment row
  (`payment_id`), an imported fee against the Stripe PaymentIntent staff
  linked (no payment row; until linked it is `:payment_not_linked`). The fee
  becomes `refunded` when the refund is recorded and goes back to `held`
  when Stripe refuses it (`hold_fee_again/3`, in the same transaction as
  the refund's `failed`). Refund progression of such a refund locks the
  person's entry → Carried Fee → payment → refund.

    * `retry_refund` / `record_manual_refund` follow a Carried Fee's failed
      refund too (the fee becomes `refunded` again), and
      `forfeit_carried_fee` — only for a Carried Fee's failed refund, while
      the fee is held — forfeits it. All three take a refund scope: a
      workshop id (its console) or `{:person, waitlist_id}` (the Waitlist
      tab). A fee confirmed or superseded since is no longer followed up.

  ## Used by other families

    * `insert_refund/4` — `Commands.Settlement` writes every Settlement
      refund through it (Reach lets only `Commands.*` call it);
    * `request_automatic_refund/3` — `Commands.Payments`
      (`complete_payment`'s `policy_failed` and `paid_after_close`).

  It calls `Commands.Payments.settle/2` to settle a reconciled Checkout
  Session. A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      signal_after_commit: 1,
      transact: 1,
      transition: 3,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1, cast_person_id: 1, fetch_attr: 2]

  import Dhc.BeginnersWorkshops.Commands.LockSpecs,
    only: [live_fee_query: 1]

  import Dhc.BeginnersWorkshops.Commands.IntakeNotices,
    only: [emailed: 1]

  import Dhc.BeginnersWorkshops.Commands.CoordinatorAlerts, only: [alert: 2]

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CarriedFee,
    CarriedFeePolicy,
    Clock,
    Intake,
    IntakeCheckout,
    IntakeEmails,
    IntakePayment,
    IntakeRefund,
    IntakeRefunds
  }

  alias Dhc.BeginnersWorkshops.Commands

  alias Dhc.BeginnersWorkshops.Commands.{
    Payments
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.{Occasion, Values}
  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @refund_outcomes %{"processing" => :processing, "completed" => :completed, "failed" => :failed}

  # How many refunds and payment rows one `reconcile` pass repairs (each);
  # the next tick takes the rest.
  @reconcile_batch 100

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run(:system, {:submit_refund, refund_id}, clock), do: submit_refund(refund_id, clock)

  def run(:stripe, {:apply_refund_event, object}, clock) when is_map(object),
    do: apply_refund_event(object, clock)

  def run(:system, :reconcile, clock), do: reconcile(clock)

  def run({:staff, principal_id}, {:retry_refund, scope, refund_id}, clock),
    do: follow_up(scope, refund_id, principal_id, :retry, clock)

  def run({:staff, principal_id}, {:record_manual_refund, scope, refund_id, attrs}, clock)
      when is_map(attrs) do
    with {:ok, note} <- manual_note(attrs),
         do: follow_up(scope, refund_id, principal_id, {:manual, note}, clock)
  end

  def run({:staff, principal_id}, {:forfeit_carried_fee, scope, refund_id}, clock),
    do: follow_up(scope, refund_id, principal_id, :forfeit, clock)

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── Refunds ─────────────────────────────────────────────────────

  # Under the payment lock of the command that found the refund owed: the
  # refund row, its submission job and "Payment refunded (automatic)", all
  # in that transaction. A payment that took nothing has nothing to refund.
  @doc false
  def request_automatic_refund(
        %{payment: payment, intake: intake, workshop: workshop},
        reason,
        reading
      ) do
    case insert_refund(payment, reason, nil, reading) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, refund} ->
        with :ok <-
               emailed(
                 IntakeEmails.deliver(
                   {:intake, intake, workshop},
                   "payment_refunded",
                   Occasion.payment_refunded(refund.payment_id),
                   reading,
                   refund: refund
                 )
               ),
             do: {:ok, refund}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The full amount originally paid, against the original payment, and its
  # submission job — the one way a refund row is requested. The source is
  # a payment row (what it took, against its PaymentIntent), or (ALE-389) a
  # Carried Fee, `{:carried_fee, fee, payment, intake}`: what the fee's
  # original payment took — its payment row (`payment`, locked by the
  # caller) or, for an imported fee, the Stripe payment staff linked —
  # recorded against `intake`, the Intake the refund is about (else the
  # original payment's own Intake, else none). Public only so
  # `Commands.Settlement` writes its refunds here too; Reach keeps it inside
  # the `Commands` namespace.
  @doc false
  @spec insert_refund(
          IntakePayment.t()
          | {:carried_fee, CarriedFee.t(), IntakePayment.t() | nil, Intake.t() | nil},
          String.t(),
          binary() | nil,
          Clock.reading()
        ) :: {:ok, IntakeRefund.t() | nil} | {:error, term()}
  def insert_refund(%IntakePayment{} = payment, reason, requested_by, reading) do
    case payment.amount_received_cents do
      amount when is_integer(amount) and amount > 0 ->
        write_refund(
          %{
            workshop_id: payment.workshop_id,
            intake_id: payment.intake_id,
            payment_id: payment.id,
            amount_cents: amount,
            currency: payment.currency_received || payment.currency,
            stripe_payment_intent_id: payment.stripe_payment_intent_id
          },
          reason,
          requested_by,
          reading
        )

      _nothing_taken ->
        {:ok, nil}
    end
  end

  def insert_refund({:carried_fee, %CarriedFee{} = fee, payment, intake}, reason, by, reading) do
    if CarriedFee.refundable_through_stripe?(fee),
      do: write_refund(fee_refund_source(fee, payment, intake), reason, by, reading),
      else: {:error, :payment_not_linked}
  end

  # What a Carried Fee's refund is made against and recorded on.
  defp fee_refund_source(fee, payment, intake) do
    %{
      workshop_id: refund_workshop(intake, payment),
      intake_id: refund_intake(intake, payment),
      payment_id: fee.payment_id,
      carried_fee_id: fee.id,
      amount_cents: fee.amount_cents || payment_field(payment, :amount_received_cents),
      currency: fee.currency,
      stripe_payment_intent_id:
        fee.stripe_payment_intent_id || payment_field(payment, :stripe_payment_intent_id)
    }
  end

  defp refund_workshop(%Intake{workshop_id: id}, _payment), do: id
  defp refund_workshop(nil, payment), do: payment_field(payment, :workshop_id)
  defp refund_intake(%Intake{id: id}, _payment), do: id
  defp refund_intake(nil, payment), do: payment_field(payment, :intake_id)
  defp payment_field(nil, _field), do: nil
  defp payment_field(%IntakePayment{} = payment, field), do: Map.fetch!(payment, field)

  defp write_refund(source, reason, requested_by, reading) do
    with {:ok, refund} <-
           source
           |> Map.merge(%{
             reason: reason,
             requested_by_principal_id: requested_by,
             requested_at: reading.now
           })
           |> IntakeRefund.request_changeset()
           |> persist(),
         :ok <- enqueue_refund(refund.id) do
      {:ok, refund}
    end
  end

  defp enqueue_refund(refund_id) do
    case %{refund_id: refund_id} |> RefundWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A refund row never changes payment or Carried Fee, so a peek never goes
  # stale; refund commands lock payment → refund, and a Carried Fee's refund
  # (ALE-389) the person's entry → the fee → payment → refund, because its
  # failure gives the fee back (one live fee per person is guarded by the
  # entry lock). A fee's person only ever changes to none (hard delete).
  defp peek_refund(query) do
    case Repo.one(query) do
      nil -> {:error, :refund_not_found}
      refund -> {:ok, refund}
    end
  end

  defp refund_spec(%IntakeRefund{id: id, payment_id: payment_id, carried_fee_id: fee_id}) do
    %{
      waitlist_entry:
        fee_id &&
          from(e in WaitlistEntry,
            where:
              e.id in subquery(
                from(f in CarriedFee, where: f.id == ^fee_id, select: f.waitlist_id)
              )
          ),
      carried_fee: fee_id && required(from(f in CarriedFee, where: f.id == ^fee_id)),
      payment: payment_id && required(from(p in IntakePayment, where: p.id == ^payment_id)),
      refund: required(from(r in IntakeRefund, where: r.id == ^id))
    }
  end

  defp cast_refund_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :refund_not_found}
    end
  end

  # ── submit_refund ───────────────────────────────────────────────

  defp submit_refund(refund_id, clock) do
    with {:ok, id} <- cast_refund_id(refund_id),
         {:ok, peek} <- peek_refund(from(r in IntakeRefund, where: r.id == ^id)),
         {:ok, plan} <- transact(fn -> with_locked(refund_spec(peek), &submission_plan/1) end) do
      case plan do
        :settled -> {:ok, %{outcome: :already_submitted}}
        {:submit, refund, source} -> submit_to_stripe(refund, source, clock)
      end
    end
  end

  # Only a `pending` refund is submitted; one Stripe already answered for
  # (processing or terminal) is left to its events.
  defp submission_plan(%{refund: %IntakeRefund{status: "pending"} = refund, payment: payment}),
    do: {:ok, {:submit, refund, payment_intent_source(refund, payment)}}

  defp submission_plan(_locked), do: {:ok, :settled}

  defp payment_intent_source(%IntakeRefund{stripe_payment_intent_id: id}, _payment)
       when is_binary(id),
       do: {:payment_intent, id}

  defp payment_intent_source(_refund, %IntakePayment{stripe_payment_intent_id: id})
       when is_binary(id),
       do: {:payment_intent, id}

  defp payment_intent_source(_refund, %IntakePayment{stripe_checkout_session_id: id})
       when is_binary(id),
       do: {:checkout_session, id}

  defp payment_intent_source(_refund, _payment), do: :unresolvable

  # Between transactions. A Stripe outage keeps the refund `pending` and
  # fails, so the worker retries; a refusal makes it `failed`.
  defp submit_to_stripe(refund, source, clock) do
    with {:ok, payment_intent} <- resolve_payment_intent(source),
         {:ok, object} <- IntakeRefunds.create(refund, payment_intent) do
      record_refund(refund, object, %{stripe_payment_intent_id: payment_intent}, clock)
    else
      {:error, :retryable, reason} ->
        note_retryable(refund, reason)
        {:error, :stripe_unavailable}

      {:error, :rejected, reason} ->
        fail_refund(refund, reason, clock)
    end
  end

  defp resolve_payment_intent({:payment_intent, id}), do: {:ok, id}

  defp resolve_payment_intent({:checkout_session, session_id}) do
    case IntakeCheckout.retrieve(session_id) do
      {:ok, session} ->
        case IntakeCheckout.outcome(session) do
          {:complete, %{payment_intent: id}} when is_binary(id) -> {:ok, id}
          _other -> {:error, :rejected, :payment_intent_not_resolvable}
        end

      {:error, failure} ->
        {:error, failure, :checkout_session_unavailable}
    end
  end

  defp resolve_payment_intent(:unresolvable),
    do: {:error, :rejected, :payment_intent_not_resolvable}

  # Writes Stripe's answer (the create's response or an event's object)
  # after a locked re-read.
  defp record_refund(refund, object, extra, clock) do
    fn -> with_locked(refund_spec(refund), &record_refund_locked(&1, object, extra, clock)) end
    |> transact()
    |> signal_after_commit()
  end

  defp record_refund_locked(
         %{refund: refund} = locked,
         %{"id" => stripe_id} = object,
         extra,
         clock
       ) do
    cond do
      refund.stripe_refund_id not in [nil, stripe_id] ->
        {:ok, {%{outcome: :not_ours}, []}}

      refund.status == "failed" ->
        {:ok, {%{outcome: :already_settled}, []}}

      refund.status == "completed" and
          not (refund.method == "stripe" and object["status"] == "failed") ->
        {:ok, {%{outcome: :already_settled}, []}}

      true ->
        settle_refund(locked, object, extra, Clock.read(clock))
    end
  end

  defp settle_refund(%{refund: refund} = locked, %{"id" => stripe_id} = object, extra, reading) do
    provider_status = object["status"]
    status = IntakeRefunds.local_status(provider_status)

    changes =
      extra
      |> Map.merge(%{
        status: status,
        stripe_refund_id: stripe_id,
        provider_status: provider_status,
        processed_at: refund.processed_at || reading.now
      })
      |> Map.merge(settled_stamps(status, object, reading))

    changeset = Ecto.Changeset.change(refund, changes)

    write =
      if status == refund.status,
        do: persist(changeset),
        else: transition(:refund, refund, changeset)

    with {:ok, refund} <- write,
         {:ok, fee} <- hold_fee_again(locked, refund, reading),
         {:ok, created} <- notify_if_failed(refund, fee) do
      {:ok, {%{outcome: Map.fetch!(@refund_outcomes, status)}, created}}
    end
  end

  defp settled_stamps("completed", _object, reading), do: %{completed_at: reading.now}

  defp settled_stamps("failed", object, reading),
    do: %{failed_at: reading.now, last_error: object["failure_reason"] || "Stripe refund failed"}

  defp settled_stamps(_processing, _object, _reading), do: %{}

  defp fail_refund(refund, reason, clock) do
    fn -> with_locked(refund_spec(refund), &fail_refund_locked(&1, reason, clock)) end
    |> transact()
    |> signal_after_commit()
  end

  defp fail_refund_locked(
         %{refund: %IntakeRefund{status: "pending"} = refund} = locked,
         reason,
         clock
       ) do
    reading = Clock.read(clock)

    changeset =
      Ecto.Changeset.change(refund,
        status: "failed",
        failed_at: reading.now,
        last_error: error_text(reason)
      )

    with {:ok, refund} <- transition(:refund, refund, changeset),
         {:ok, fee} <- hold_fee_again(locked, refund, reading),
         {:ok, created} <- notify_if_failed(refund, fee),
         do: {:ok, {%{outcome: :failed}, created}}
  end

  defp fail_refund_locked(_settled, _reason, _clock),
    do: {:ok, {%{outcome: :already_settled}, []}}

  defp note_retryable(refund, reason) do
    _ =
      transact(fn ->
        with_locked(refund_spec(refund), fn
          %{refund: %IntakeRefund{status: "pending"} = refund} ->
            refund |> Ecto.Changeset.change(last_error: error_text(reason)) |> persist()

          %{refund: refund} ->
            {:ok, refund}
        end)
      end)

    :ok
  end

  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 2_000)

  # ALE-389: a Carried Fee whose refund Stripe refused is held again, so the
  # person keeps their seat entitlement until a coordinator retries, records
  # a manual refund or forfeits it. A fee is `refunded` only by its one live
  # refund, so a `refunded` fee here is this refund's. If the person has
  # since come to hold another live fee (one per person), or has paid an
  # open Intake through Stripe (a held fee beside a paid seat would be two
  # entitlements), this one stays `refunded`: the money is still owed back,
  # and the failed refund is followed up by Retry or Record manual refund.
  defp hold_fee_again(
         %{carried_fee: %CarriedFee{id: id, status: "refunded"} = fee},
         %IntakeRefund{status: "failed", carried_fee_id: id},
         reading
       ) do
    if other_live_fee?(fee) or paid_by_stripe_since?(fee),
      do: {:ok, fee},
      else:
        transition(:carried_fee, fee, CarriedFee.status_changeset(fee, "held", nil, reading.now))
  end

  defp hold_fee_again(_locked, _refund, _reading), do: {:ok, nil}

  defp other_live_fee?(%CarriedFee{waitlist_id: nil}), do: false

  defp other_live_fee?(%CarriedFee{id: id, waitlist_id: waitlist_id}),
    do: Repo.exists?(from(f in live_fee_query(waitlist_id), where: f.id != ^id))

  defp paid_by_stripe_since?(%CarriedFee{waitlist_id: nil}), do: false

  defp paid_by_stripe_since?(%CarriedFee{waitlist_id: waitlist_id}),
    do:
      Repo.exists?(
        from(i in Intake,
          where: i.waitlist_id == ^waitlist_id and i.state == "paid" and i.paid_via == "stripe"
        )
      )

  # A failed refund is a coordinator's job (story 84): a keyed Notification
  # per refund row, so a retried command never notifies twice.
  # `fee` is what `hold_fee_again/3` left: held again, or still `refunded`
  # (the money is still owed back, so there is nothing to forfeit).
  defp notify_if_failed(%IntakeRefund{status: "failed"} = refund, fee) do
    %{first_name: first_name, date: date} = refund_person(refund)
    workshop = if date, do: " for the Beginners' Workshop on #{Values.date(date)}", else: ""

    follow_up =
      case {refund.carried_fee_id, fee} do
        {nil, _fee} ->
          "Retry it or record a manual refund from the workshop console."

        {_fee_id, %CarriedFee{status: "held"}} ->
          "It was a Carried Fee refund, so the fee is held again: retry it, record a manual " <>
            "refund or forfeit the fee from the workshop console or the Waitlist."

        {_fee_id, %CarriedFee{status: "refunded"}} ->
          "It was a Carried Fee refund and the person has since paid or holds another fee, so " <>
            "the money is still owed back: retry it or record a manual refund from the " <>
            "workshop console or the Waitlist."

        {_fee_id, _fee} ->
          "It was a Carried Fee refund: retry it or record a manual refund from the workshop " <>
            "console or the Waitlist."
      end

    alert(
      "beginners-workshop-refund:#{refund.id}:failed",
      "A refund of #{Values.refund_amount(refund)} to #{first_name || "an anonymised person"}" <>
        "#{workshop} failed. " <> follow_up
    )
  end

  defp notify_if_failed(_refund, _fee), do: {:ok, []}

  # Who a refund pays back: the person of its Intake, or of its Carried Fee
  # when it has none (an imported fee's refund, ALE-389).
  defp refund_person(%IntakeRefund{intake_id: intake_id}) when is_binary(intake_id) do
    from(i in Intake,
      join: w in BeginnersWorkshop,
      on: w.id == i.workshop_id,
      left_join: p in UserProfile,
      on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
      where: i.id == ^intake_id,
      limit: 1,
      select: %{first_name: p.first_name, date: w.date}
    )
    |> Repo.one!()
  end

  defp refund_person(%IntakeRefund{carried_fee_id: fee_id}) do
    from(f in CarriedFee,
      left_join: p in UserProfile,
      on: p.waitlist_id == f.waitlist_id and not is_nil(f.waitlist_id),
      where: f.id == ^fee_id,
      limit: 1,
      select: %{first_name: p.first_name, date: nil}
    )
    |> Repo.one!()
  end

  # ── apply_refund_event ──────────────────────────────────────────

  # Our refund by its Stripe id, or — when the event beat the submission's
  # record — by the refund id in its metadata. Anything else is a Workshop
  # refund (or no one's), which the Workshops target owns.
  defp apply_refund_event(%{"id" => stripe_id} = object, clock) when is_binary(stripe_id) do
    case peek_refund_for(object) do
      nil -> {:ok, %{outcome: :not_ours}}
      refund -> record_refund(refund, object, %{}, clock)
    end
  end

  defp apply_refund_event(_object, _clock), do: {:ok, %{outcome: :not_ours}}

  defp peek_refund_for(%{"id" => stripe_id} = object) do
    Repo.one(from(r in IntakeRefund, where: r.stripe_refund_id == ^stripe_id)) ||
      with id when is_binary(id) <- IntakeRefunds.refund_id(object),
           {:ok, id} <- Ecto.UUID.cast(id) do
        Repo.get(IntakeRefund, id)
      else
        _ -> nil
      end
  end

  # ── reconcile ───────────────────────────────────────────────────

  # One bounded pass repairing missed events: pending refunds are enqueued
  # again (the job is unique while incomplete), processing ones re-read from
  # Stripe, and live or releasing payment rows settled when their Checkout
  # Session completed or expired. Expired holds stay `reap_holds`'s job.
  defp reconcile(clock) do
    now = Clock.read(clock).now

    resubmitted =
      from(r in IntakeRefund,
        where: r.status == "pending",
        order_by: [asc: r.updated_at, asc: r.id],
        limit: @reconcile_batch,
        select: r.id
      )
      |> Repo.all()
      |> Enum.count(&(enqueue_refund(&1) == :ok))

    refunds =
      from(r in IntakeRefund,
        where: r.status == "processing" and not is_nil(r.stripe_refund_id),
        order_by: [asc: r.updated_at, asc: r.id],
        limit: @reconcile_batch
      )
      |> Repo.all()
      |> Enum.map(&reconcile_refund(&1, clock))

    payments =
      from(p in IntakePayment,
        where:
          not is_nil(p.stripe_checkout_session_id) and
            ((p.status == "open" and p.expires_at > ^now) or p.status == "releasing"),
        order_by: [asc: p.updated_at, asc: p.id],
        limit: @reconcile_batch,
        select: p.stripe_checkout_session_id
      )
      |> Repo.all()
      |> Enum.map(&reconcile_payment(&1, clock))

    {:ok,
     %{
       refunds_resubmitted: resubmitted,
       refunds_settled: Enum.count(refunds, &(&1 == :settled)),
       refunds_waiting: Enum.count(refunds, &(&1 == :waiting)),
       payments_settled: Enum.count(payments, &(&1 in [:released, :completed])),
       payments_waiting: Enum.count(payments, &(&1 == :waiting))
     }}
  end

  defp reconcile_refund(refund, clock) do
    with {:ok, object} <- IntakeRefunds.retrieve(refund.stripe_refund_id),
         {:ok, %{outcome: outcome}} when outcome in [:completed, :failed] <-
           record_refund(refund, object, %{}, clock) do
      :settled
    else
      _still_processing_or_unavailable -> :waiting
    end
  end

  defp reconcile_payment(session_id, clock) do
    case IntakeCheckout.retrieve(session_id) do
      {:ok, session} -> Payments.settle(session, clock)
      {:error, _unavailable} -> :waiting
    end
  end

  # ── retry_refund / record_manual_refund ─────────────────────────

  defp manual_note(attrs) do
    case fetch_attr(attrs, :note) do
      nil ->
        {:ok, nil}

      note when is_binary(note) ->
        {:ok, note |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))}

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp follow_up(scope, refund_id, principal_id, action, clock) do
    with {:ok, scoped} <- refund_scope(scope),
         {:ok, refund_id} <- cast_refund_id(refund_id),
         {:ok, peek} <- peek_refund(from(r in scoped, where: r.id == ^refund_id)) do
      transact(fn ->
        with_locked(refund_spec(peek), &follow_up_locked(&1, action, principal_id, clock))
      end)
    end
  end

  # A workshop console follows up its Intakes' refunds; the Waitlist tab
  # (ALE-389) the refunds of the person's Carried Fees.
  defp refund_scope({:person, waitlist_id}) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      {:ok,
       from(r in IntakeRefund,
         join: f in CarriedFee,
         on: f.id == r.carried_fee_id,
         where: f.waitlist_id == ^waitlist_id
       )}
    end
  end

  defp refund_scope(workshop_id) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         do: {:ok, from(r in IntakeRefund, where: r.workshop_id == ^workshop_id)}
  end

  defp follow_up_locked(
         %{refund: failed, carried_fee: fee} = locked,
         :forfeit,
         _principal_id,
         clock
       ) do
    reading = Clock.read(clock)

    with :ok <- CarriedFeePolicy.check(:forfeit, follow_up_facts(locked, reading)),
         {:ok, fee} <-
           transition(
             :carried_fee,
             fee,
             CarriedFee.status_changeset(fee, "forfeited", nil, reading.now)
           ) do
      {:ok, %{id: fee.id, status: fee.status, refund_id: failed.id}}
    end
  end

  defp follow_up_locked(%{refund: failed, carried_fee: fee} = locked, action, principal_id, clock) do
    reading = Clock.read(clock)

    with :ok <-
           CarriedFeePolicy.check(follow_up_command(action), follow_up_facts(locked, reading)),
         {:ok, refund} <- follow_up_row(action, failed, locked.payment, principal_id, reading),
         {:ok, _fee} <- refund_fee_again(fee, reading) do
      {:ok, refund_view(refund)}
    end
  end

  defp follow_up_command({:manual, _note}), do: :manual
  defp follow_up_command(:retry), do: :retry

  # ALE-389: `CarriedFeePolicy` decides a follow-up from the refund
  # followed up — failed, with no follow-up row and (for a Carried Fee's)
  # still the fee's latest — and the fee it refunds, which must still be
  # owed back.
  defp follow_up_facts(%{refund: refund, carried_fee: fee} = locked, reading) do
    CarriedFeePolicy.facts(
      fee: fee,
      refund: refund && %{status: refund.status, followed_up: followed_up?(refund, fee)},
      entry: Map.get(locked, :waitlist_entry),
      now: reading.now
    )
  end

  # Every refund writer of a payment holds its lock; the follows index is
  # the backstop.
  defp followed_up?(%IntakeRefund{status: "failed", id: id} = refund, fee) do
    Repo.exists?(from(r in IntakeRefund, where: r.follows_refund_id == ^id)) or
      (fee != nil and superseded?(refund))
  end

  defp followed_up?(_not_failed, _fee), do: false

  # A later refund of the same Carried Fee (a new Refund Carried Fee or
  # Cancel with refund after this one failed) is the one to follow up.
  defp superseded?(%IntakeRefund{id: id, carried_fee_id: fee_id, created_at: at}) do
    Repo.exists?(
      from(r in IntakeRefund,
        where: r.carried_fee_id == ^fee_id and r.id != ^id and r.created_at > ^at
      )
    )
  end

  defp refund_fee_again(%CarriedFee{status: "held"} = fee, reading),
    do:
      transition(
        :carried_fee,
        fee,
        CarriedFee.status_changeset(fee, "refunded", nil, reading.now)
      )

  defp refund_fee_again(fee, _reading), do: {:ok, fee}

  # A new key against the same payment; no email (story 144).
  defp follow_up_row(:retry, failed, payment, principal_id, reading) do
    with {:ok, refund} <-
           %{
             workshop_id: failed.workshop_id,
             intake_id: failed.intake_id,
             payment_id: failed.payment_id,
             carried_fee_id: failed.carried_fee_id,
             follows_refund_id: failed.id,
             reason: failed.reason,
             amount_cents: failed.amount_cents,
             currency: failed.currency,
             stripe_payment_intent_id:
               failed.stripe_payment_intent_id || (payment && payment.stripe_payment_intent_id),
             requested_by_principal_id: principal_id,
             requested_at: reading.now
           }
           |> IntakeRefund.request_changeset()
           |> persist(),
         :ok <- enqueue_refund(refund.id) do
      {:ok, refund}
    end
  end

  defp follow_up_row({:manual, note}, failed, _payment, principal_id, reading),
    do: failed |> IntakeRefund.manual_changeset(principal_id, note, reading.now) |> persist()

  defp refund_view(%IntakeRefund{} = refund) do
    Map.take(refund, [
      :id,
      :intake_id,
      :payment_id,
      :carried_fee_id,
      :follows_refund_id,
      :status,
      :method,
      :reason,
      :amount_cents,
      :currency,
      :requested_at,
      :completed_at,
      :failed_at
    ])
  end
end
