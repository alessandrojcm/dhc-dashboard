defmodule Dhc.BeginnersWorkshops.Commands.Payments do
  @moduledoc """
  The Intake payment commands (ALE-381, ALE-405): `start_payment` and the
  person's own `confirm` (`{:intake_link, token}`), `complete_payment` and
  `release_payment` (`:stripe`) and the `reap_holds` sweep pass (`:system`).
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.
  `IntakeCheckout` is the only Stripe Checkout caller, reached only from
  here.

  ## Intake payment (ALE-381)

  Seats taken = Intakes in `paid` + payment rows in `open` (Seat Holds);
  `WorkshopFacts` counts them and `WorkshopPolicy` judges them.

    * `start_payment` (`{:intake_link, token}`) is refused with
      `:after_cutoff` or `:full`. Otherwise it takes the Seat Hold under the
      Beginners' Workshop lock — an `open` payment row with the fee frozen
      and 30 minutes to run — and then, **between transactions**, creates the
      Checkout Session (`IntakeCheckout.create/2`, idempotency key
      `beginners-intake-payment:<id>`) and records it after re-reading the
      row under the lock. While a hold is live, pressing Pay again reuses its
      session. A hold whose 30 minutes ran out is `:payment_in_progress`
      until Stripe ends it. A session Stripe refused to create frees the hold
      at once (no session exists that could still be paid).
    * `complete_payment` (`:stripe`) runs from `checkout.session.completed`
      and from the success return (which passes the session id, so it is
      retrieved server-side). It is idempotent and always finds the row by
      session id. An amount or non-`eur` currency mismatch makes the row
      `policy_failed`, leaves the Intake `contacted` and requests the
      automatic refund (ALE-382). Otherwise the row becomes `paid`; an open
      Intake becomes `paid` (`paid_via: stripe`) and "Place confirmed –
      paid" is queued with its log row in the same transaction, and the
      coordinator-alert holders get a keyed "place paid" Notification
      (`beginners-intake:<id>:paid`, signalled after commit, so also a Web
      Push), while a
      completion for an Intake that already closed (or a `releasing` hold)
      requests the automatic refund instead.
    * `release_payment` (`:stripe`) runs on `checkout.session.expired`.
    * `reap_holds` (`:system`, a sweep pass) asks Stripe to expire every
      session whose hold ran out and settles the row from Stripe's answer
      (expired → released, completed → paid). Our clock alone never frees a
      seat.

  A payment-started command peeks the row by session id without a lock,
  then locks Beginners' Workshop → Intake → payment from the top down and
  decides on the re-read row. The row's workshop and Intake never change,
  so the peek never goes stale.

  ## Carried Fees (ALE-388)

    * A holder of a `held` Carried Fee who is contacted (a Batch, a
      fast-track, a resent link) gets "Contact – confirm (Carried Fee)".
    * `confirm` (the person, `{:intake_link, token}`, or a console Intake
      command) moves a `contacted` Intake whose person holds a `held` fee
      to `paid` (`paid_via: carried_fee`) and the fee to `applied`, in one
      transaction with no Stripe call and no Seat Hold; it is refused with
      `:full` (the same seat rule as a hold) or `:no_carried_fee`. The
      Payment Cutoff does not stop it — the cutoff pass leaves a holder's
      `contacted` Intake open, and Attendance Finalisation settles it — so it
      is allowed until finalisation. "Place confirmed – Carried Fee" is
      queued, and Pre-workshop info too when the cutoff has passed.
    * `start_payment` is refused with `:confirm_instead` for a holder, and
      `fast_track` after the cutoff places holders only.

  ## Cross-family calls

    * an automatic refund (`policy_failed`, `paid_after_close`) is
      requested through `Commands.Refunds.request_automatic_refund/3`;
    * the person's `confirm` runs the console command's rule and act through
      `Commands.IntakeCommands.intake_command_locked/4`.

  `settle/2` (a Checkout Session's outcome, settled through the webhook
  paths) is used by `Commands.Refunds`' `reconcile`. A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query
  require Logger

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      signal_after_commit: 1,
      transact: 1,
      transition: 3,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.CoordinatorAlerts, only: [alert: 2]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [facts_for: 1]

  import Dhc.BeginnersWorkshops.Commands.LockSpecs,
    only: [
      entry_query: 1,
      intake_spec: 2,
      locked_intake_fee: 1,
      open_payment: 1
    ]

  import Dhc.BeginnersWorkshops.Commands.Facts,
    only: [held?: 1]

  import Dhc.BeginnersWorkshops.Commands.IntakeNotices,
    only: [place_confirmed: 3]

  alias Dhc.BeginnersWorkshops.{
    Clock,
    Intake,
    IntakeCheckout,
    IntakeLink,
    IntakePayment,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands

  alias Dhc.BeginnersWorkshops.Commands.{
    IntakeCommands,
    NotificationCopy,
    Refunds
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  # How many expired holds one `reap_holds` pass settles; the next sweep
  # takes the rest.
  @reap_batch 100
  # A payment row whose Checkout Session may still need recording: a live
  # hold, or one releasing because its Intake closed meanwhile.
  @unsessioned_statuses ~w(open releasing)

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run({:intake_link, token}, :start_payment, clock), do: start_payment(token, clock)

  def run({:intake_link, token}, :confirm, clock), do: confirm_by_link(token, clock)

  def run(:stripe, {:complete_payment, session}, clock) do
    with {:ok, session} <- session_object(session), do: complete_payment(session, clock)
  end

  def run(:stripe, {:release_payment, session}, clock) do
    with {:ok, session} <- session_object(session), do: release_payment(session, clock)
  end

  def run(:system, :reap_holds, clock), do: reap_holds(clock)

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── start_payment ───────────────────────────────────────────────

  defp start_payment(token, clock) do
    with {:ok, peek} <- peek_intake(token),
         {:ok, row} <- transact(fn -> hold_locked(peek, clock) end) do
      checkout(row, clock)
    end
  end

  # The person's entry is locked too: the hold freezes their email for the
  # Checkout Session, read from the locked row.
  defp hold_locked(peek, clock) do
    peek
    |> intake_spec(fn _locked -> open_payment(peek.intake_id) end)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
    |> with_locked(&take_hold(&1, clock))
  end

  # The Intake a link resolves to (unlocked): only its stored hash matches.
  defp peek_intake(token) do
    hash = IntakeLink.hash(token)

    from(i in Intake,
      where: i.link_token_hash == ^hash,
      select: %{intake_id: i.id, workshop_id: i.workshop_id, waitlist_id: i.waitlist_id}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      peek -> {:ok, peek}
    end
  end

  # Seats are judged under the workshop lock, which every hold takes, so N
  # people racing for the last seat get exactly one hold.
  defp take_hold(%{workshop: workshop, intake: intake, payment: open} = locked, clock) do
    reading = Clock.read(clock)

    cond do
      intake.state == "paid" -> {:error, :already_paid}
      intake.state != "contacted" or workshop.status != "scheduled" -> {:error, :intake_closed}
      # A Carried Fee holder is never asked for money twice (ALE-388).
      held?(locked.carried_fee) -> {:error, :confirm_instead}
      open != nil -> live_hold(open, reading)
      true -> new_hold(workshop, intake, Map.get(locked, :waitlist_entry), reading)
    end
  end

  # Pressing Pay again reuses a live hold; one whose 30 minutes ran out
  # waits for Stripe to end its session.
  defp live_hold(open, reading) do
    if DateTime.compare(open.expires_at, reading.now) == :gt,
      do: {:ok, open},
      else: {:error, :payment_in_progress}
  end

  # The hold freezes every Checkout Session parameter from the locked rows
  # (`IntakeCheckout.hold_params/4`), so a later rotation, email edit or
  # reschedule can never change what a replayed create sends.
  defp new_hold(workshop, intake, entry, reading) do
    cond do
      not WorkshopPolicy.payment_open?(workshop, reading) ->
        {:error, :after_cutoff}

      not WorkshopPolicy.seat_free?(workshop, facts_for(workshop)) ->
        {:error, :full}

      true ->
        workshop
        |> IntakeCheckout.hold_params(intake, entry, WorkshopPolicy.hold_expires_at(reading))
        |> IntakePayment.hold_changeset()
        |> persist()
    end
  end

  # Between transactions: reuse the live hold's session, or create it.
  defp checkout(%IntakePayment{checkout_url: url}, _clock) when is_binary(url),
    do: {:ok, %{checkout_url: url, client_secret: nil, session_id: nil}}

  defp checkout(%IntakePayment{stripe_checkout_session_id: id}, _clock) when is_binary(id) do
    case IntakeCheckout.retrieve(id) do
      {:ok, %{"status" => "open", "client_secret" => secret}} when is_binary(secret) ->
        {:ok, %{checkout_url: nil, client_secret: secret, session_id: id}}

      _other ->
        {:error, :payment_unavailable}
    end
  end

  defp checkout(%IntakePayment{} = row, clock) do
    case create_session(row, clock) do
      {:ok, %{id: id, client_secret: secret}} when is_binary(secret) ->
        {:ok, %{checkout_url: nil, client_secret: secret, session_id: id}}

      {:ok, %{url: url}} when is_binary(url) ->
        {:ok, %{checkout_url: url, client_secret: nil, session_id: nil}}

      {:ok, _no_credentials} ->
        {:error, :payment_unavailable}

      {:error, _reason} ->
        {:error, :payment_unavailable}
    end
  end

  # Creates (or replays) the row's Checkout Session, with exactly the
  # parameters the hold froze, and records it. A session Stripe refused to
  # create cannot exist, so its hold is freed; a refusal that does not prove
  # that (`IntakeCheckout` classes an idempotency conflict as retryable)
  # keeps the hold.
  defp create_session(%IntakePayment{} = row, clock) do
    case IntakeCheckout.create(row) do
      {:ok, session} ->
        record_session(row, session)

      {:error, :rejected} ->
        _ = release_unsessioned(row, clock)
        {:error, :payment_unavailable}

      {:error, :retryable} ->
        {:error, :payment_unavailable}
    end
  end

  # After an authoritative re-read: the session is recorded once; a
  # concurrent press that recorded it first wins (the idempotency key makes
  # it the same session).
  defp record_session(row, session),
    do: transact(fn -> with_locked(payment_spec(row), &record_session_locked(&1, session)) end)

  defp record_session_locked(%{payment: payment}, %{id: session_id, url: url} = session) do
    cond do
      payment.stripe_checkout_session_id == session_id ->
        {:ok, %{session | url: payment.checkout_url}}

      payment.status in @unsessioned_statuses and is_nil(payment.stripe_checkout_session_id) ->
        with {:ok, payment} <-
               payment |> IntakePayment.session_changeset(session_id, url) |> persist(),
             do: {:ok, %{session | url: payment.checkout_url}}

      true ->
        {:error, :concurrent_change}
    end
  end

  defp release_unsessioned(row, clock),
    do: transact(fn -> with_locked(payment_spec(row), &release_unsessioned_locked(&1, clock)) end)

  defp release_unsessioned_locked(%{payment: payment}, clock) do
    if payment.status in @unsessioned_statuses and is_nil(payment.stripe_checkout_session_id),
      do: release(payment, Clock.read(clock).now),
      else: {:ok, payment}
  end

  defp payment_spec(%{id: id, workshop_id: workshop_id, intake_id: intake_id}),
    do:
      intake_spec(
        %{workshop_id: workshop_id, intake_id: intake_id},
        required(from(p in IntakePayment, where: p.id == ^id))
      )

  defp release(payment, at),
    do:
      transition(
        :payment,
        payment,
        Ecto.Changeset.change(payment, status: "released", released_at: at, checkout_email: nil)
      )

  # ── complete_payment / release_payment ──────────────────────────

  # A webhook passes the event's session object; the success return passes
  # only the id, so the session is retrieved server-side.
  defp session_object(%{"id" => id} = session) when is_binary(id), do: {:ok, session}

  defp session_object(id) when is_binary(id) and id != "" do
    case IntakeCheckout.retrieve(id) do
      {:ok, session} -> {:ok, session}
      {:error, :retryable} -> {:error, :payment_unavailable}
      {:error, :rejected} -> {:error, :not_found}
    end
  end

  defp session_object(_session), do: {:error, :not_found}

  defp peek_payment(session_id),
    do: Repo.one(from(p in IntakePayment, where: p.stripe_checkout_session_id == ^session_id))

  defp complete_payment(%{"id" => session_id} = session, clock) do
    case peek_payment(session_id) do
      nil ->
        # Ours but not recorded yet (the webhook beat `record_session`): fail
        # so the webhook retries; the reaper repairs it otherwise.
        if IntakeCheckout.ours?(session),
          do: {:error, :session_not_recorded},
          else: {:ok, %{outcome: :not_ours}}

      row ->
        transact(fn ->
          with_locked(payment_spec(row), &complete_locked(&1, session, clock))
        end)
        |> signal_after_commit()
    end
  end

  defp complete_locked(%{payment: payment} = locked, session, clock) do
    reading = Clock.read(clock)

    case {payment.status, IntakeCheckout.outcome(session)} do
      {status, _outcome} when status in ~w(paid policy_failed released) ->
        {:ok, {%{outcome: :already_recorded}, []}}

      {_status, {:complete, details}} ->
        if details.amount == payment.amount_cents and details.currency == payment.currency,
          do: record_paid(locked, details, reading),
          else: record_policy_failure(locked, details, reading)

      {_status, _not_paid} ->
        {:ok, {%{outcome: :not_paid}, []}}
    end
  end

  defp record_policy_failure(%{payment: payment} = locked, details, reading) do
    changeset =
      Ecto.Changeset.change(payment,
        status: "policy_failed",
        policy_failed_at: reading.now,
        amount_received_cents: details.amount,
        currency_received: details.currency,
        stripe_payment_intent_id: details.payment_intent
      )

    with {:ok, payment} <- transition(:payment, payment, changeset),
         {:ok, _refund} <-
           Refunds.request_automatic_refund(
             %{locked | payment: payment},
             "policy_failed",
             reading
           ),
         do: {:ok, {%{outcome: :policy_failed}, []}}
  end

  defp record_paid(%{payment: payment, intake: intake, workshop: workshop}, details, reading) do
    was_open? = payment.status == "open"

    changeset =
      Ecto.Changeset.change(payment,
        status: "paid",
        paid_at: reading.now,
        amount_received_cents: details.amount,
        currency_received: details.currency,
        stripe_payment_intent_id: details.payment_intent
      )

    with {:ok, payment} <- transition(:payment, payment, changeset) do
      if was_open? and intake.state == "contacted",
        do: pay_intake(intake, workshop, reading),
        else: refund_after_close(%{payment: payment, intake: intake, workshop: workshop}, reading)
    end
  end

  # A completion for a hold whose Intake already closed (or that was
  # releasing): the payment is recorded and refunded in full at once.
  defp refund_after_close(locked, reading) do
    with {:ok, _refund} <- Refunds.request_automatic_refund(locked, "paid_after_close", reading),
         do: {:ok, {%{outcome: :paid_after_close}, []}}
  end

  defp pay_intake(intake, workshop, reading) do
    with {:ok, intake} <-
           transition(:intake, intake, Intake.paid_changeset(intake, "stripe", reading.now)),
         :ok <- place_confirmed(intake, workshop, reading),
         {:ok, created} <- notify_paid(intake, workshop) do
      {:ok, {%{outcome: :paid}, created}}
    end
  end

  # A keyed Notification (and so a Web Push) to the coordinator-alert holders
  # for each Intake paid through Stripe, inserted in this transaction and
  # signalled after commit; the key makes a replayed completion notify once.
  defp notify_paid(intake, workshop) do
    first_name =
      intake.waitlist_id &&
        Repo.one(
          from(p in UserProfile,
            where: p.waitlist_id == ^intake.waitlist_id,
            limit: 1,
            select: p.first_name
          )
        )

    alert(
      "beginners-intake:#{intake.id}:paid",
      NotificationCopy.place_paid(first_name, workshop.date)
    )
  end

  defp release_payment(%{"id" => session_id} = session, clock) do
    case {IntakeCheckout.outcome(session), peek_payment(session_id)} do
      {:expired, nil} ->
        # Not recorded (or not ours): the reaper settles an unrecorded hold.
        {:ok, %{outcome: :not_ours}}

      {:expired, row} ->
        transact(fn -> with_locked(payment_spec(row), &release_locked(&1, clock)) end)

      {_still_open_or_complete, _row} ->
        {:ok, %{outcome: :not_expired}}
    end
  end

  defp release_locked(%{payment: payment}, clock) do
    if payment.status in ~w(open releasing) do
      with {:ok, _payment} <- release(payment, Clock.read(clock).now),
           do: {:ok, %{outcome: :released}}
    else
      {:ok, %{outcome: :already_recorded}}
    end
  end

  # ── reap_holds ──────────────────────────────────────────────────

  # Holds whose 30 minutes ran out. Each is settled from Stripe's answer
  # through the same locked paths as the webhooks; a hold Stripe has not
  # ended stays open (and its seat taken) until the next pass. A releasing
  # hold whose session was never recorded is settled the same way, or a
  # payment made through its session could never be matched and refunded.
  defp reap_holds(clock) do
    now = Clock.read(clock).now

    from(p in IntakePayment,
      where: p.expires_at <= ^now,
      where:
        p.status == "open" or
          (p.status == "releasing" and is_nil(p.stripe_checkout_session_id)),
      order_by: [asc: p.expires_at, asc: p.id],
      limit: @reap_batch
    )
    |> Repo.all()
    |> Enum.reduce(%{released: 0, completed: 0, waiting: 0}, fn row, tally ->
      Map.update!(tally, reap(row, clock), &(&1 + 1))
    end)
    |> then(&{:ok, &1})
  end

  defp reap(%IntakePayment{stripe_checkout_session_id: nil} = row, clock) do
    # The session was never recorded: replaying the create either returns
    # the session Stripe made (then settle it) or proves none exists.
    case create_session(row, clock) do
      {:ok, %{id: session_id}} -> reap_session(session_id, clock)
      {:error, _reason} -> if released?(row), do: :released, else: :waiting
    end
  end

  defp reap(%IntakePayment{stripe_checkout_session_id: session_id}, clock),
    do: reap_session(session_id, clock)

  defp reap_session(session_id, clock) do
    outcome =
      with {:error, _not_open} <- IntakeCheckout.expire(session_id),
           {:error, _unavailable} <- IntakeCheckout.retrieve(session_id) do
        :waiting
      else
        {:ok, session} -> settle(session, clock)
      end

    # Log only the closed outcome, after the authoritative settlement. No
    # session id, Intake link, customer details or provider body is disclosed.
    Logger.info("[beginners-payments] Checkout cleanup outcome=#{outcome}")
    outcome
  end

  @doc false
  def settle(session, clock) do
    case IntakeCheckout.outcome(session) do
      :expired ->
        if match?({:ok, %{outcome: :released}}, release_payment(session, clock)),
          do: :released,
          else: :waiting

      {:complete, _details} ->
        if match?({:ok, _}, complete_payment(session, clock)), do: :completed, else: :waiting

      _open_or_unpaid ->
        :waiting
    end
  end

  defp released?(%IntakePayment{id: id}),
    do: Repo.exists?(from(p in IntakePayment, where: p.id == ^id and p.status == "released"))

  # The person's own confirm from their Intake page: the console command's
  # rule and act, with no actor and no note.
  defp confirm_by_link(token, clock) do
    with {:ok, peek} <- peek_intake(token),
         {:ok, %{outcome: outcome}} <-
           transact(fn ->
             peek
             |> intake_spec(nil)
             |> Map.put(:carried_fee, &locked_intake_fee/1)
             |> with_locked(
               &IntakeCommands.intake_command_locked(
                 &1,
                 :confirm,
                 %{actor: nil, note: nil, options: %{}},
                 clock
               )
             )
           end) do
      {:ok, %{outcome: outcome}}
    end
  end
end
