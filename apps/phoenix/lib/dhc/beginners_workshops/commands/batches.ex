defmodule Dhc.BeginnersWorkshops.Commands.Batches do
  @moduledoc """
  The commands that contact people (ALE-405): `send_due_batch` (`:system`)
  and `fast_track` (`beginners.workshops.manage`). Both create `contacted`
  Intakes through one `contact/4`, whose Contact email
  (`IntakeEmails.deliver/5` with `:contact`) is the one Contact-email path.
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.

  ## Automatic Batches (ALE-380)

  `send_due_batch` (`:system`, run by the periodic sweep) sends a workshop's
  next Batch only when `WorkshopPolicy.batch_due?/3` holds under the
  Beginners' Workshop lock and someone eligible is waiting. The Batch is the
  live `BatchProposal` of `WorkshopPolicy.batch_size/2` people; their
  Waitlist entries are locked and re-checked, and a person taken by a
  concurrent command makes the pass retry from a fresh proposal. Each new
  Intake queues its Contact email through `IntakeEmails.deliver/5`, which
  writes the Intake Email ledger row and prepares an opaque delivery plan in
  the same transaction. `enqueue_offer_round/2` seals the plans into provider
  chunks of at most 100 before commit, and the coordinator-alert
  holders get a keyed "Batch sent" Notification (signalled after commit).
  With free seats but nobody eligible waiting it sends one keyed
  Notification per workshop and nothing else. The Batch number's unique
  index and the Intake states keep a pass exactly-once.

  ## Fast-track (ALE-384)

  `fast_track` places one person straight into a workshop outside Batch
  order: a `waiting` Waitlist entry, a `removed` one within the 3-month
  retention window (restored to `waiting` through `Dhc.Waitlist.restore/2`)
  or a new person added through the staff path `Dhc.Waitlist.add_person/2`,
  all inside this transaction under the Beginners' Workshop lock and then the
  person's Waitlist entry lock. It is refused with `:open_intake`,
  `:not_eligible` (attended, invited or joined, or removed too long ago) and
  `:after_cutoff`, and the staff path's own refusals pass through. The new
  `contacted` Intake has origin `fast_track` and no Batch; its Contact email
  is the Batch one, with `{{windowEnd}}` rendering its Payment Window
  (`WorkshopPolicy.payment_window_end/3`: the Payment Cutoff, or the workshop
  start for a Carried Fee holder placed after it). The person pays the
  workshop fee like everyone else.

  No staff command sends email itself; `fast_track`'s Contact email is
  queued by the Intake it creates, exactly as a Batch's is.

  ## Cross-family calls

  None: the coordinator alerts are `Commands.CoordinatorAlerts`', the
  workshop rules `Commands.WorkshopRules`', the Carried Fee read
  `Commands.Facts`' and `Commands.LockSpecs`'. A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      signal_after_commit: 1,
      transact: 1,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [facts_for: 1, still_scheduled: 1]

  import Dhc.BeginnersWorkshops.Commands.LockSpecs,
    only: [live_fee_query: 1]

  import Dhc.BeginnersWorkshops.Commands.Facts,
    only: [held?: 1]

  import Dhc.BeginnersWorkshops.Commands.CoordinatorAlerts, only: [alert: 2]

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BatchProposal,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmails,
    IntakeLink,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands
  alias Dhc.BeginnersWorkshops.Commands.NotificationCopy

  alias Dhc.BeginnersWorkshops.IntakeEmails.Occasion
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  # A Batch pass that loses a proposed person to a concurrent command retries
  # from a fresh proposal this many times before giving up until the next
  # sweep.
  @batch_attempts 3

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run(:system, {:send_due_batch, workshop_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         do: send_due_batch(workshop_id, clock, @batch_attempts)
  end

  def run({:staff, _principal_id}, {:fast_track, workshop_id, person}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, person} <- fast_track_person(person) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: fast_track_entry_query(person),
            carried_fee: fn
              %{waitlist_entry: %WaitlistEntry{id: id}} -> live_fee_query(id)
              _new_person -> nil
            end
          },
          &fast_track_locked(&1, person, clock)
        )
      end)
    end
  end

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── send_due_batch ──────────────────────────────────────────────

  defp send_due_batch(workshop_id, clock, attempts_left) do
    transact(fn ->
      with_locked(
        %{
          workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
          waitlist_entry: &lock_proposal(&1, clock)
        },
        &send_batch_locked(&1, clock)
      )
    end)
    |> signal_after_commit()
    |> case do
      {:error, :concurrent_change} when attempts_left > 1 ->
        send_due_batch(workshop_id, clock, attempts_left - 1)

      result ->
        result
    end
  end

  # Under the workshop lock: when a Batch is due, lock the proposed people's
  # Waitlist entries (in id order). Nothing is locked when it is not due.
  defp lock_proposal(%{workshop: workshop}, clock) do
    facts = facts_for(workshop)

    if WorkshopPolicy.batch_due?(workshop, facts, Clock.read(clock)) do
      ids =
        workshop
        |> WorkshopPolicy.batch_size(facts)
        |> BatchProposal.people()
        |> Enum.map(& &1.waitlist_id)

      {:all, from(e in WaitlistEntry, where: e.id in ^ids)}
    end
  end

  # The "no open window" rule and the rest of `batch_due?/3` are judged
  # again here, with the time read under the lock.
  defp send_batch_locked(%{workshop: workshop, waitlist_entry: entries}, clock) do
    reading = Clock.read(clock)
    facts = facts_for(workshop)

    cond do
      is_nil(entries) or not WorkshopPolicy.batch_due?(workshop, facts, reading) ->
        {:ok, {%{outcome: :not_due}, []}}

      entries == [] ->
        with {:ok, created} <- notify_nobody_waiting(workshop),
             do: {:ok, {%{outcome: :nobody_waiting}, created}}

      true ->
        with {:ok, people} <- still_the_proposal(entries, workshop, facts) do
          create_batch(workshop, facts, people, reading)
        end
    end
  end

  # The Batch is exactly the live proposal at this moment (the one the
  # console previews): read again with the proposed entries locked, it must
  # be those very people. Someone taken by a concurrent command (another
  # workshop's Batch, a fast-track), no longer waiting, or overtaken by an
  # earlier priority makes the pass retry from a fresh proposal.
  defp still_the_proposal(entries, workshop, facts) do
    live = workshop |> WorkshopPolicy.batch_size(facts) |> BatchProposal.people()
    locked = Map.new(entries, &{&1.id, &1})

    if MapSet.new(live, & &1.waitlist_id) == MapSet.new(Map.keys(locked)) do
      {:ok, Enum.map(live, &%{entry: Map.fetch!(locked, &1.waitlist_id)})}
    else
      {:error, :concurrent_change}
    end
  end

  # ── fast_track ──────────────────────────────────────────────────

  defp fast_track_person({:waitlist_entry, id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, {:waitlist_entry, id}}
      :error -> {:error, :person_not_found}
    end
  end

  defp fast_track_person({:new_person, attrs}) when is_map(attrs), do: {:ok, {:new_person, attrs}}
  defp fast_track_person(_person), do: {:error, :invalid_payload}

  # An existing person's entry is locked after the workshop. A new person
  # has no entry yet: the staff path locks and inserts it under ours.
  defp fast_track_entry_query({:waitlist_entry, id}),
    do: from(e in WaitlistEntry, where: e.id == ^id)

  defp fast_track_entry_query({:new_person, _attrs}), do: nil

  defp fast_track_locked(%{workshop: workshop, waitlist_entry: entry} = locked, person, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         :ok <- payment_open(workshop, locked.carried_fee, reading),
         {:ok, entry, placed} <- fast_track_entry(person, entry, reading),
         :ok <- contactable(entry),
         {:ok, intake, _delivery} <- contact(workshop, :fast_track, entry, reading) do
      {:ok, fast_track_view(intake, placed)}
    end
  end

  # After the cutoff only a holder of a `held` Carried Fee may be placed:
  # they confirm, so a late placement never needs a Stripe payment (story 38).
  defp payment_open(workshop, fee, reading) do
    if WorkshopPolicy.payment_open?(workshop, reading) or held?(fee),
      do: :ok,
      else: {:error, :after_cutoff}
  end

  defp fast_track_entry({:waitlist_entry, _id}, nil, _reading), do: {:error, :person_not_found}

  defp fast_track_entry({:waitlist_entry, _id}, %WaitlistEntry{} = entry, reading) do
    with :ok <- no_open_intake(entry) do
      place_existing(entry, reading)
    end
  end

  defp fast_track_entry({:new_person, attrs}, nil, reading) do
    with {:ok, %{id: id}} <- Waitlist.add_person(attrs, now: reading.now) do
      {:ok, Repo.get!(WaitlistEntry, id), :added}
    end
  end

  defp place_existing(%WaitlistEntry{status: "waiting"} = entry, _reading),
    do: {:ok, entry, :waiting}

  # Checked here first so the restore (which runs in this transaction)
  # cannot refuse and leave it marked for rollback.
  defp place_existing(%WaitlistEntry{status: "removed", removed_at: %DateTime{}} = entry, reading) do
    if Waitlist.restorable?(entry.removed_at, reading.now) do
      with {:ok, _view} <- Waitlist.restore(entry.id, now: reading.now) do
        {:ok, Repo.get!(WaitlistEntry, entry.id), :restored}
      end
    else
      {:error, :not_eligible}
    end
  end

  defp place_existing(%WaitlistEntry{}, _reading), do: {:error, :not_eligible}

  # Read under the person's entry lock, which every Intake writer takes; the
  # one-open-Intake index is the backstop.
  defp no_open_intake(%WaitlistEntry{id: id}) do
    open = Intake.open_states()

    if Repo.exists?(from(i in Intake, where: i.waitlist_id == ^id and i.state in ^open)),
      do: {:error, :open_intake},
      else: :ok
  end

  # The Contact email is addressed by first name, so an anonymised person
  # (no email or profile) cannot be placed.
  defp contactable(%WaitlistEntry{email: nil}), do: {:error, :not_eligible}

  defp contactable(%WaitlistEntry{id: id}) do
    case Repo.one(from(p in UserProfile, where: p.waitlist_id == ^id, select: p.first_name)) do
      nil -> {:error, :not_eligible}
      _first_name -> :ok
    end
  end

  defp fast_track_view(%Intake{} = intake, placed) do
    intake
    |> Map.take([:id, :workshop_id, :waitlist_id, :state, :origin, :contacted_at])
    |> Map.put(:placed, placed)
  end

  defp create_batch(workshop, facts, people, reading) do
    number = facts.batches_sent + 1
    window_end = WorkshopPolicy.window_end(workshop, reading)

    with {:ok, batch} <-
           %{
             workshop_id: workshop.id,
             number: number,
             size: length(people),
             sent_at: reading.now,
             window_ends_at: window_end
           }
           |> Batch.changeset()
           |> persist(),
         :ok <- contact_all(workshop, batch, people, reading),
         {:ok, created} <- notify_batch_sent(workshop, batch) do
      {:ok, {%{outcome: :sent, batch: batch_view(batch)}, created}}
    end
  end

  defp contact_all(workshop, batch, people, reading) do
    Enum.reduce_while(people, {:ok, []}, fn %{entry: entry}, {:ok, plans} ->
      case contact(workshop, {:batch, batch}, entry, reading) do
        {:ok, _intake, plan} -> {:cont, {:ok, [plan | plans]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> IntakeEmails.enqueue_offer_round(batch.id, Enum.reverse(plans))
      error -> error
    end
  end

  # One new `contacted` Intake and its Contact email (with the person's own
  # link and the Intake's Payment Window), logged — all in this transaction.
  defp contact(workshop, origin, entry, reading) do
    intake_id = Ecto.UUID.generate()
    token = IntakeLink.token(intake_id, 1)

    {origin, batch_id} =
      case origin do
        {:batch, %Batch{id: batch_id}} -> {"batch", batch_id}
        :fast_track -> {"fast_track", nil}
      end

    with {:ok, intake} <-
           %{
             id: intake_id,
             workshop_id: workshop.id,
             waitlist_id: entry.id,
             origin: origin,
             batch_id: batch_id,
             queue_date: entry.initial_registration_date,
             link_token_hash: IntakeLink.hash(token),
             contacted_at: reading.now
           }
           |> Intake.contact_changeset()
           |> persist(),
         {:ok, delivery} <-
           IntakeEmails.deliver(
             {:intake, intake, workshop},
             :contact,
             Occasion.contact(),
             reading,
             offer_round: not is_nil(batch_id)
           ) do
      {:ok, intake, delivery}
    end
  end

  defp batch_view(%Batch{} = batch) do
    Map.take(batch, [:id, :workshop_id, :number, :size, :sent_at, :window_ends_at])
  end

  # Keyed Notifications to the coordinator-alert holders, inserted in this
  # transaction; the caller signals the created rows after commit.
  defp notify_batch_sent(workshop, batch) do
    alert(
      "beginners-workshop:#{workshop.id}:batch:#{batch.number}",
      NotificationCopy.batch_sent(workshop.date, batch.number, batch.size)
    )
  end

  defp notify_nobody_waiting(workshop) do
    alert(
      "beginners-workshop:#{workshop.id}:nobody-waiting",
      NotificationCopy.nobody_waiting(workshop.date)
    )
  end
end
