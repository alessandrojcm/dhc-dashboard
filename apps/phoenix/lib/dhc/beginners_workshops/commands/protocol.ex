defmodule Dhc.BeginnersWorkshops.Commands.Protocol do
  @moduledoc """
  The protocol core of the Beginners' Workshop write boundary (ADR 0029 and
  its second amendment, ALE-403): the one lock primitive, the one transition
  table, the one `persist/1`, `transact/1` and the keyed-Notification
  plumbing. Its functions are public so the internal `Commands.*` modules can
  share them, but Reach (`.reach.exs`) lets only
  `Dhc.BeginnersWorkshops.Commands` and `Dhc.BeginnersWorkshops.Commands.*`
  call them, and this module is the only caller of `Repo.transaction` in the
  context. Everything else reaches a write through
  `Dhc.BeginnersWorkshops.execute/3`.

  ## The protocol

  Every command body runs as

      transact(fn ->
        with_locked(spec, fn locked ->
          reading = Clock.read(clock)   # the time, read under the lock
          decide from the locked rows (WorkshopPolicy, WorkshopFacts)
          write through persist/1 (and transition/3 for a status change)
        end)
      end)

  **Lock order is part of the contract: Beginners' Workshop → Waitlist entry
  → Intake → Carried Fee → payment → refund.** `with_locked/2` is the only
  function in the boundary that takes a row lock, and it walks `@lock_levels`
  in that order; a command may skip levels but can never lock upward, and a
  spec key outside the levels raises. A command that starts from a payment or
  refund (webhooks, the refund worker) will peek it unlocked, lock what it
  points to from the top down, re-read and retry if it moved (the ADR 0027
  rule).

  **Stripe is called only between transactions**, with the result written
  after an authoritative re-read under the lock.

  **One transition table** (`@transitions`) declares every legal status
  change, and `transition/3` is the only writer of a status:

      Beginners' Workshop  scheduled → finalised | cancelled
      Intake               contacted → paid | lapsed | returned | declined
                           paid → attended | no_show | deferred
                              | cancelled_refunded | withdrawn
                           attended → no_show
                           no_show → attended | deferred
      payment (Seat Hold)  open → paid | releasing | released | policy_failed
                           releasing → released | paid
      refund               pending → processing | completed | failed
                           completed → failed (Stripe asynchronous failure only)
                           processing → completed | failed
      Carried Fee          held → applied | refunded | forfeited
                           applied → held | spent | refunded | forfeited
                           refunded → held (its Stripe refund failed)
                           spent → forfeited
                           forfeited → spent | held

  The workshop end states are terminal. Intakes are created `contacted`
  (ALE-380); ALE-381 adds `contacted → paid` and the payment rows; ALE-385
  adds the Payment Cutoff's `contacted → lapsed | returned`; ALE-391 adds
  Attendance Finalisation's `paid → attended | no_show`; ALE-386 adds
  `decline`'s `contacted → declined`; ALE-388 adds `defer`'s
  `paid → deferred` and the Carried Fee; ALE-387 adds cancel with refund's
  and withdraw's `paid → cancelled_refunded | withdrawn`; ALE-393 adds the
  attendance corrections (`attended ↔ no_show`, `no_show → deferred`, and the Carried
  Fee's `spent ↔ forfeited`, `forfeited → held`). A Stripe refund
  is created `pending`; a manual refund is written `completed` (both by
  `persist/1`, the transition table governs every later change). Later
  Intake moves and Carried Fees join the table with the tickets that
  create them.

  **Constraints are translated, never raised.** `persist/1` declares every
  unique and check constraint and turns a violation into a domain reason or a
  field error.

  **Notifications follow the commit.** `create_keyed/1` writes a command's
  keyed Notifications inside its transaction and returns the rows it
  created; the command returns `{:ok, {result, created}}`, and
  `signal_after_commit/1` signals them once the transaction has committed
  (ADR 0025: the row is the source of truth; the channel follows the commit).
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    CarriedFee,
    Intake,
    IntakeEvent,
    IntakePayment,
    IntakeRefund,
    StaffAssignment
  }

  alias Dhc.Notifications
  alias Dhc.Repo

  @lock_levels [:workshop, :waitlist_entry, :intake, :carried_fee, :payment, :refund]

  @transitions %{
    workshop: %{"scheduled" => ~w(finalised cancelled)},
    intake: %{
      "contacted" => ~w(paid lapsed returned declined),
      "paid" => ~w(attended no_show deferred cancelled_refunded withdrawn),
      # Attendance corrections after finalisation (ALE-393).
      "attended" => ~w(no_show),
      "no_show" => ~w(attended deferred)
    },
    payment: %{
      "open" => ~w(paid releasing released policy_failed),
      "releasing" => ~w(released paid)
    },
    # Stripe can answer success on create and report failure asynchronously.
    # Manual completions stay settled in record_refund_locked/4.
    refund: %{
      "pending" => ~w(processing completed failed),
      "processing" => ~w(completed failed),
      "completed" => ~w(failed)
    },
    # ALE-389: a fee is `refunded` once its refund is requested and goes
    # back to `held` if Stripe refuses that refund.
    carried_fee: %{
      "held" => ~w(applied refunded forfeited),
      "applied" => ~w(held spent refunded forfeited),
      "refunded" => ~w(held),
      # Attendance corrections (ALE-393) move a used fee to match.
      "spent" => ~w(forfeited),
      "forfeited" => ~w(spent held)
    }
  }

  # The status field of each entity in the transition table.
  @status_fields %{
    workshop: :status,
    intake: :state,
    payment: :status,
    refund: :status,
    carried_fee: :status
  }

  # Unique and check constraints, as the migrations named them, and what each
  # becomes. Unique constraints become a domain reason; check constraints
  # become a field error on the changeset (the changesets already enforce the
  # same shape, so these are the backstop for writers outside the seam).
  @unique_constraints %{
    BeginnersWorkshop => [],
    Batch => [{:number, "beginners_workshop_batches_number_index", :concurrent_change}],
    Intake => [
      {:waitlist_id, "beginners_workshop_intakes_one_open_per_person_index", :concurrent_change},
      {:link_token_hash, "beginners_workshop_intakes_link_token_hash_index", :concurrent_change}
    ],
    # Staff rows are written under the workshop lock, so these are backstops.
    StaffAssignment => [
      {:principal_id, "beginners_workshop_staff_workshop_principal_unique", :staff_conflict},
      {:workshop_id, "beginners_workshop_staff_one_coach", :staff_conflict}
    ],
    # Holds are taken under the Intake lock, so these are backstops.
    IntakePayment => [
      {:intake_id, "beginners_workshop_intake_payments_one_open_index", :concurrent_change},
      {:stripe_checkout_session_id, "beginners_workshop_intake_payments_session_index",
       :concurrent_change}
    ],
    # Refunds are written under the payment lock, so these are backstops.
    IntakeRefund => [
      {:payment_id, "beginners_workshop_intake_refunds_one_live_index", :already_requested},
      {:follows_refund_id, "beginners_workshop_intake_refunds_follows_index",
       :refund_followed_up},
      {:idempotency_key, "beginners_workshop_intake_refunds_idempotency_key_index",
       :concurrent_change},
      {:stripe_refund_id, "beginners_workshop_intake_refunds_stripe_refund_index",
       :concurrent_change},
      {:carried_fee_id, "beginners_workshop_intake_refunds_one_live_per_fee_index",
       :already_requested}
    ],
    # Carried Fees are written under the person's entry or Intake lock and
    # then the Carried Fee lock, so these are backstops.
    CarriedFee => [
      {:waitlist_id, "beginners_workshop_carried_fees_one_live_per_person_index",
       :concurrent_change},
      {:payment_id, "beginners_workshop_carried_fees_payment_index", :concurrent_change},
      {:stripe_payment_intent_id, "beginners_workshop_carried_fees_payment_intent_index",
       :payment_already_linked}
    ]
  }

  @check_constraints %{
    BeginnersWorkshop => [
      {:status, "beginners_workshops_status_check"},
      {:status, "beginners_workshops_finalised_check"},
      {:venue, "beginners_workshops_venue_check"},
      {:capacity, "beginners_workshops_capacity_check"},
      {:fee_cents, "beginners_workshops_fee_check"},
      {:payment_window_days, "beginners_workshops_payment_window_check"},
      {:reschedule_count, "beginners_workshops_reschedule_count_check"},
      {:status, "beginners_workshops_cancelled_check"},
      {:cancel_reason, "beginners_workshops_cancel_reason_check"}
    ],
    Batch => [
      {:number, "beginners_workshop_batches_number_check"},
      {:size, "beginners_workshop_batches_size_check"},
      {:window_ends_at, "beginners_workshop_batches_window_check"}
    ],
    Intake => [
      {:state, "beginners_workshop_intakes_state_check"},
      {:origin, "beginners_workshop_intakes_origin_check"},
      {:link_generation, "beginners_workshop_intakes_link_generation_check"},
      {:paid_via, "beginners_workshop_intakes_paid_via_check"},
      {:state, "beginners_workshop_intakes_paid_check"},
      {:checked_in_at, "beginners_workshop_intakes_check_in_check"},
      {:carried_fee_id, "beginners_workshop_intakes_carried_fee_check"},
      {:anonymised_at, "beginners_workshop_intakes_anonymised_check"},
      {:invitation_outcome, "beginners_workshop_intakes_invitation_outcome_check"}
    ],
    CarriedFee => [
      {:status, "beginners_workshop_carried_fees_status_check"},
      {:origin, "beginners_workshop_carried_fees_origin_check"},
      {:applied_intake_id, "beginners_workshop_carried_fees_applied_check"},
      {:amount_cents, "beginners_workshop_carried_fees_amount_check"},
      {:stripe_payment_intent_id, "beginners_workshop_carried_fees_link_check"}
    ],
    IntakePayment => [
      {:status, "beginners_workshop_intake_payments_status_check"},
      {:amount_cents, "beginners_workshop_intake_payments_amount_check"},
      {:currency, "beginners_workshop_intake_payments_currency_check"}
    ],
    StaffAssignment => [{:role, "beginners_workshop_staff_role_check"}],
    IntakeEvent => [
      {:note, "beginners_workshop_intake_events_note_check"},
      {:correction, "beginners_workshop_intake_events_correction_check"}
    ],
    IntakeRefund => [
      {:status, "beginners_workshop_intake_refunds_status_check"},
      {:method, "beginners_workshop_intake_refunds_method_check"},
      {:amount_cents, "beginners_workshop_intake_refunds_amount_check"},
      {:carried_fee_id, "beginners_workshop_intake_refunds_source_check"}
    ]
  }

  # ── Introspection (tests reach these through `Commands`) ────────

  @doc false
  @spec transitions() :: %{atom() => %{String.t() => [String.t()]}}
  def transitions, do: @transitions

  @doc false
  @spec transition_allowed?(atom(), String.t(), String.t()) :: boolean()
  def transition_allowed?(entity, from, to),
    do: to in (@transitions |> Map.get(entity, %{}) |> Map.get(from, []))

  @doc false
  @spec lock_levels() :: [atom()]
  def lock_levels, do: @lock_levels

  @doc false
  # Constraint names `persist/1` translates; a test checks each one exists.
  @spec declared_constraints() :: [String.t()]
  def declared_constraints do
    for constraints <- [@unique_constraints, @check_constraints],
        {_schema, list} <- constraints,
        declared <- list,
        do: elem(declared, 1)
  end

  # ── The lock primitive ──────────────────────────────────────────

  # `spec` maps lock levels to a query (`nil` skips the level), a
  # `required(query)` (a missing row is `:not_found`), `{:all, query}` (every
  # row, locked in id order) or a function of the rows locked so far. Levels
  # are always taken in `@lock_levels` order.
  @doc false
  @spec with_locked(map(), (map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_locked(spec, fun) when is_map(spec) do
    case Map.keys(spec) -- @lock_levels do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown lock level(s) #{inspect(unknown)}"
    end

    @lock_levels
    |> Enum.reduce_while({:ok, %{}}, fn level, {:ok, locked} ->
      case spec |> Map.get(level) |> resolve_spec(locked) |> lock_rows() do
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

  defp lock_rows(nil), do: {:ok, nil}

  defp lock_rows({:all, query}) do
    {:ok,
     query
     |> exclude(:order_by)
     |> order_by([row], asc: row.id)
     |> lock("FOR UPDATE")
     |> Repo.all()}
  end

  defp lock_rows({:required, query}) do
    case lock_rows(query) do
      {:ok, nil} -> {:error, :not_found}
      found -> found
    end
  end

  defp lock_rows(%Ecto.Query{} = query), do: {:ok, query |> lock("FOR UPDATE") |> Repo.one()}

  @doc false
  @spec required(Ecto.Query.t()) :: {:required, Ecto.Query.t()}
  def required(query), do: {:required, query}

  @doc false
  @spec transact((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ── transition/3 ────────────────────────────────────────────────

  # The only writer of a status: refuses a change the table does not list,
  # then persists the changeset (which also carries the change's stamps).
  @doc false
  @spec transition(atom(), struct(), Ecto.Changeset.t()) :: {:ok, struct()} | {:error, term()}
  def transition(entity, row, %Ecto.Changeset{} = changeset) do
    field = Map.fetch!(@status_fields, entity)
    from = Map.fetch!(row, field)
    to = Ecto.Changeset.get_field(changeset, field)

    if transition_allowed?(entity, from, to),
      do: persist(changeset),
      else: {:error, :illegal_transition}
  end

  # ── persist/1 ───────────────────────────────────────────────────

  @doc false
  @spec persist(Ecto.Changeset.t()) :: {:ok, struct()} | {:error, atom() | Ecto.Changeset.t()}
  def persist(%Ecto.Changeset{data: %schema{}} = changeset) do
    changeset
    |> declare_constraints(schema)
    |> insert_or_update()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{} = failed} -> {:error, constraint_reason(failed, schema)}
    end
  end

  defp insert_or_update(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset),
    do: Repo.insert(changeset)

  defp insert_or_update(changeset), do: Repo.update(changeset)

  defp declare_constraints(changeset, schema) do
    changeset =
      @unique_constraints
      |> Map.get(schema, [])
      |> Enum.reduce(changeset, fn {field, name, _reason}, acc ->
        Ecto.Changeset.unique_constraint(acc, field, name: name)
      end)

    @check_constraints
    |> Map.get(schema, [])
    |> Enum.reduce(changeset, fn {field, name}, acc ->
      Ecto.Changeset.check_constraint(acc, field, name: name, message: "is invalid")
    end)
  end

  # A unique violation becomes its declared reason; anything else (field
  # validation, a check constraint) stays the changeset.
  defp constraint_reason(%Ecto.Changeset{errors: errors} = changeset, schema) do
    reasons =
      Map.new(Map.get(@unique_constraints, schema, []), fn {_f, name, reason} ->
        {name, reason}
      end)

    Enum.find_value(errors, changeset, fn {_field, {_message, meta}} ->
      Map.get(reasons, to_string(Keyword.get(meta, :constraint_name)))
    end)
  end

  # ── Keyed Notifications ─────────────────────────────────────────

  # The one writer of the boundary's keyed Notifications: each
  # `{principal_id, key, body}` inside this transaction. Returns the rows
  # created, for `signal_after_commit/1` once the transaction commits; a
  # failure rolls the command back.
  @doc false
  @spec create_keyed([{binary(), String.t(), String.t()}]) :: {:ok, [struct()]} | {:error, term()}
  def create_keyed(notifications) do
    Enum.reduce_while(notifications, {:ok, []}, fn {principal_id, key, body}, {:ok, acc} ->
      case Notifications.create_keyed_in_transaction(principal_id, key, body) do
        {:ok, :created, notification} -> {:cont, {:ok, [notification | acc]}}
        {:ok, :already_created} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Signals the Notifications a committed command created (ADR 0025: the row
  # is the source of truth; the channel follows the commit).
  @doc false
  @spec signal_after_commit({:ok, {term(), [struct()]}} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  def signal_after_commit({:ok, {result, created}}) do
    Enum.each(created, &Notifications.signal_created/1)
    {:ok, result}
  end

  def signal_after_commit(error), do: error
end
