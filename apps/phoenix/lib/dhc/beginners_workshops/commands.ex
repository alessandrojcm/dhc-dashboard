defmodule Dhc.BeginnersWorkshops.Commands do
  @moduledoc """
  ALE-378 (ADR 0029 and its amendments): the one interface of every
  Beginners' Workshop write. `Dhc.BeginnersWorkshops.execute/3` delegates
  here; nothing else in the context opens a write transaction (the one
  `Repo.transaction` is `Commands.Protocol.transact/1`). Staff commands,
  the person's Intake-page commands, Stripe-driven commands and time-driven
  passes all arrive as a `command` with an `actor`. This module authorizes
  the actor and routes the command to its family module; it holds no
  command logic.

  ## The protocol

  Every command body runs inside the protocol core,
  `Dhc.BeginnersWorkshops.Commands.Protocol` (ADR 0029, second amendment):
  `transact/1` around `with_locked/2`, the clock read under the lock, and
  every write through `persist/1` (`transition/3` for a status change).
  Its moduledoc holds the transition table, the constraint translation and
  the signal-after-commit rule. **The lock order is Beginners' Workshop →
  Waitlist entry → Intake → Carried Fee → payment → refund**: a command may
  skip levels but never lock upward, and Stripe is called only between
  transactions.

  What a closing does to the person — standing, Seat Hold, Carried Fee,
  refund, notice — is one row of `Commands.Settlement` (ALE-404), keyed by
  cause and ending and run inside the command's `with_locked/2`. A command
  decides whether it may run (`IntakePolicy`, `CarriedFeePolicy`,
  `WorkshopPolicy`), names the row, and writes its own history row.

  ## Actors

    * `{:staff, principal_id}` — authorized through `Dhc.Auth.Capabilities`
      for the command's capability (`@staff_capabilities`) **before any
      read**; an assignment-scoped capability (`beginners.workshops.run`) is
      decided against the workshop's Staff rows, and a denial conceals the
      workshop (`:not_found`);
    * `{:intake_link, token}` — the person's Intake page;
    * `:stripe` — webhook and success-return completions;
    * `:system` — time-driven passes and workers;
    * `{:intake_reply, intake_reply_id}` (ALE-411) — a Reply Action: the
      command an Intake Reply asked for, run by
      `IntakeReplies.forward/2`. Authorized for exactly
      `@intake_reply_commands` (`decline`, `defer`, `cancel_with_refund`,
      `withdraw` with `refund: true` only, `refund_carried_fee`,
      `resend_link`) and only for a recorded Intake Reply; it never reaches
      `forfeit_carried_fee`. The boundary's locked policy re-check still
      decides, and the Intake history row names the reply, not a Principal.

  ## Clock

  `opts[:clock]` is a `Dhc.BeginnersWorkshops.Clock` (default: the wall
  clock). It is read inside the lock, so a decision never uses an instant
  taken before the rows were held. Tests pass `Clock.fixed/1`.

  ## Routing (ALE-405)

  After authorization, `@families` maps the command name to the family
  module that runs it (`Family.run/3`, which casts its own input). A console
  Intake command — `{command, workshop_id, intake_id, attrs}` with the
  command in `IntakePolicy.commands/0` — is routed by its shape first,
  because `withdraw` and `refund_carried_fee` are also the Waitlist tab's
  `{command, waitlist_id, attrs}` and `confirm` the person's own `:confirm`.
  Each family's moduledoc documents its commands:

    * `Commands.Schedule` — `schedule_workshop`, `update_workshop`,
      `reschedule_workshop`, `cancel_workshop`, `pause_batches`,
      `resume_batches`;
    * `Commands.Batches` — `send_due_batch`, `fast_track`;
    * `Commands.Payments` — `start_payment`, `confirm` by Intake link,
      `complete_payment`, `release_payment`, `reap_holds`;
    * `Commands.Refunds` — `submit_refund`, `apply_refund_event`,
      `reconcile`, `retry_refund`, `record_manual_refund`,
      `forfeit_carried_fee` (and `insert_refund/4`, the one refund-row
      writer);
    * `Commands.IntakeCommands` — the console Intake commands (`decline`,
      `defer`, `confirm`, `cancel_with_refund`, `withdraw`, `resend_link`,
      `rotate_link`, `refund_carried_fee`, `correct_attendance`);
    * `Commands.People` — the Waitlist tab's `withdraw` and
      `refund_carried_fee`, `link_carried_fee_payment`, `delete_person`,
      `purge_retention`, `import_carried_fee`;
    * `Commands.Attendance` — `check_in`, `undo_check_in`,
      `pass_payment_cutoff`, `finish_workshop`, `finalise_attendance`,
      `send_follow_ups`, `invite`;
    * `Commands.Staff` — `set_staff` and the Staff Notifications;
    * `Commands.Replies` — `alert_reply_waiting` (an Intake Reply that could
      not be forwarded, ALE-409).

  To add a command: its capability in `@staff_capabilities` (or its actor
  list; a Reply Action also joins `@intake_reply_commands`), its name in `@families`, a `run/3` clause in its family module, and
  its docs in that family's moduledoc. A family never calls another
  family's private functions: shared helpers are public `@doc false`
  functions of the module that owns their concept (each family's moduledoc
  lists the ones it offers and uses) or of the small internal modules
  `Commands.Input`, `Commands.WorkshopRules`, `Commands.LockSpecs`,
  `Commands.Facts`, `Commands.IntakeHistory`, `Commands.IntakeNotices`,
  `Commands.CoordinatorAlerts` and `Commands.NotificationCopy` (the text of
  every Notification). Reach lets only `Commands` and `Commands.*`
  call any of them.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}
  alias Dhc.BeginnersWorkshops.{Clock, IntakePolicy, IntakeReply, StaffAssignment}

  alias Dhc.BeginnersWorkshops.Commands.{
    Attendance,
    Batches,
    IntakeCommands,
    Payments,
    People,
    Protocol,
    Refunds,
    Replies,
    Schedule,
    Staff
  }

  alias Dhc.Repo

  @type principal_id :: binary()

  @type actor ::
          {:staff, principal_id()}
          | {:intake_link, token :: String.t()}
          | :stripe
          | :system
          | {:intake_reply, intake_reply_id :: binary()}

  @typedoc """
  Schedule attributes use internal keys (string or atom): `venue`, `date`,
  `start_time`, `capacity`, `fee_cents`, and the optional
  `payment_cutoff_date`, `payment_cutoff_time` (Dublin civil; default the
  start time 3 days before), `contact_from` (default the Dublin day it is
  scheduled) and `payment_window_days` (default 7), plus optional Staff.
  Update attributes are any of `capacity`, `fee_cents`,
  `payment_cutoff_date`, `payment_cutoff_time`, `contact_from`,
  `payment_window_days`.

  Reschedule attributes are any of `venue`, `date`, `start_time`,
  `payment_cutoff_date`, `payment_cutoff_time` and `contact_from`; at least
  one of the date, start time and venue must change.

  Staff attributes (`set_staff`, and optional on a schedule) are
  `coach_principal_id` (`nil` for no coach) and `assistant_principal_ids`
  (a list). `set_staff` replaces the whole Staff list.
  """
  @type command ::
          {:schedule_workshop, [map()]}
          | {:update_workshop, workshop_id :: binary(), map()}
          | {:reschedule_workshop, workshop_id :: binary(), map()}
          | {:cancel_workshop, workshop_id :: binary(), map()}
          | {:pause_batches, workshop_id :: binary()}
          | {:resume_batches, workshop_id :: binary()}
          | {:send_due_batch, workshop_id :: binary()}
          | {:set_staff, workshop_id :: binary(), map()}
          | :start_payment
          | :confirm
          | {:import_carried_fee, waitlist_id :: binary(), paid_text :: String.t()}
          | {:complete_payment, session_id_or_object :: String.t() | map()}
          | {:release_payment, session_id_or_object :: String.t() | map()}
          | :reap_holds
          | {:pass_payment_cutoff, workshop_id :: binary()}
          | {:fast_track, workshop_id :: binary(), fast_track_person()}
          | {:submit_refund, refund_id :: binary()}
          | {:apply_refund_event, stripe_refund :: map()}
          | :reconcile
          | {:retry_refund, refund_scope(), refund_id :: binary()}
          | {:record_manual_refund, refund_scope(), refund_id :: binary(), map()}
          | {:forfeit_carried_fee, refund_scope(), refund_id :: binary()}
          | {:refund_carried_fee, waitlist_id :: binary(), map()}
          | {:link_carried_fee_payment, waitlist_id :: binary(), map()}
          | {:check_in, workshop_id :: binary(), intake_id :: binary()}
          | {:undo_check_in, workshop_id :: binary(), intake_id :: binary()}
          | {:finish_workshop, workshop_id :: binary()}
          | {:finalise_attendance, workshop_id :: binary()}
          | {:send_follow_ups, workshop_id :: binary()}
          | {:invite, workshop_id :: binary(), intake_id :: binary()}
          | {:delete_person, waitlist_id :: binary(), map()}
          | {:purge_retention, waitlist_id :: binary()}
          | {:alert_reply_waiting, resend_email_id :: String.t()}
          | {IntakePolicy.command(), workshop_id :: binary(), intake_id :: binary(), map()}

  @typedoc """
  Who `fast_track` places: an existing Waitlist entry by id, or a new
  person's registration details (the public registration body, string keys).
  """
  @type fast_track_person :: {:waitlist_entry, binary()} | {:new_person, map()}

  @typedoc """
  Where a failed refund is followed up from (ALE-389): a workshop's console
  (its id; the refund is about one of its Intakes) or a person's Waitlist
  entry (`{:person, waitlist_id}`; their Carried Fee's refund).
  """
  @type refund_scope :: binary() | {:person, binary()}

  @typedoc """
  A refusal. A failed `schedule_workshop` names the (0-based) workshop it
  failed on: `{:workshop, index, reason}`.
  """
  @type error ::
          :forbidden
          | :unknown_command
          | :not_found
          | :no_workshops
          | :too_many_workshops
          | :start_in_past
          | :invalid_payment_cutoff
          | :invalid_contact_from
          | :contact_from_locked
          | :fee_locked
          | :concurrent_change
          | :after_finalisation
          | :already_cancelled
          | :invalid_staff
          | :not_a_coach
          | :not_a_member
          | :staff_conflict
          | :capacity_below_taken
          | :after_cutoff
          | :full
          | :already_paid
          | :intake_closed
          | :payment_in_progress
          | :payment_unavailable
          | :session_not_recorded
          | :illegal_transition
          | :person_not_found
          | :open_intake
          | :not_eligible
          | :email_on_waitlist
          | :email_is_principal
          | :email_has_pending_invitation
          | :invalid_payload
          | :refund_not_found
          | :refund_not_failed
          | :refund_followed_up
          | :already_requested
          | :stripe_unavailable
          | :check_in_not_open
          | :check_in_closed
          | :not_paid
          | :not_due
          | :not_finalised
          | :not_attended
          | :already_invited
          | :already_joined
          | :not_invitable
          | :incomplete_details
          | :intake_not_found
          | :invalid_note
          | :intake_not_paid
          | :carried_fee_paid
          | :refund_choice_required
          | :invalid_refund_choice
          | :nothing_to_refund
          | :person_not_found
          | :no_carried_fee
          | :confirm_instead
          | :payment_not_found
          | :carried_fee_applied
          | :carried_fee_not_held
          | :not_a_carried_fee_refund
          | :payment_not_linked
          | :not_imported
          | :already_linked
          | :payment_already_linked
          | :invalid_payment_reference
          | :stripe_payment_not_found
          | :payment_not_succeeded
          | :payment_already_refunded
          | :fee_not_refundable
          | :invalid_reason
          | :before_finalisation
          | :not_correctable
          | :invalid_correction
          | :not_deletable
          | Ecto.Changeset.t()
          | {:workshop, non_neg_integer(), atom() | Ecto.Changeset.t()}

  # Command → the capability a staff actor needs. Every staff command is
  # listed; `authorize/2` refuses anything else before a read.
  @staff_capabilities %{
    schedule_workshop: :"beginners.workshops.manage",
    update_workshop: :"beginners.workshops.manage",
    reschedule_workshop: :"beginners.workshops.manage",
    cancel_workshop: :"beginners.workshops.manage",
    pause_batches: :"beginners.workshops.manage",
    resume_batches: :"beginners.workshops.manage",
    set_staff: :"beginners.workshops.manage",
    fast_track: :"beginners.workshops.manage",
    retry_refund: :"beginners.workshops.manage",
    record_manual_refund: :"beginners.workshops.manage",
    # Assignment-scoped (ALE-379): authorized against the workshop's Staff.
    check_in: :"beginners.workshops.run",
    undo_check_in: :"beginners.workshops.run",
    finish_workshop: :"beginners.workshops.run",
    # ALE-392: the Invitation handoff is an Invitation, so it needs the
    # Invitation capability (which the beginners coordinator holds).
    invite: :"members.invite",
    # Console Intake commands (ALE-386).
    decline: :"beginners.workshops.manage",
    # Carried Fees (ALE-388).
    defer: :"beginners.workshops.manage",
    confirm: :"beginners.workshops.manage",
    resend_link: :"beginners.workshops.manage",
    rotate_link: :"beginners.workshops.manage",
    # ALE-387. `withdraw` is the Waitlist's own exit, offered on the Waitlist
    # tab and the console, so it needs the Waitlist capability.
    cancel_with_refund: :"beginners.workshops.manage",
    withdraw: :"beginners.waitlist.manage",
    # Carried Fee refunds and forfeits (ALE-389): money, so the manager's.
    refund_carried_fee: :"beginners.workshops.manage",
    link_carried_fee_payment: :"beginners.workshops.manage",
    forfeit_carried_fee: :"beginners.workshops.manage",
    # ALE-393.
    correct_attendance: :"beginners.workshops.manage",
    # ALE-396: deleting a person is a Waitlist decision (the money choice is
    # the one `withdraw` already asks).
    delete_person: :"beginners.waitlist.manage"
  }

  # The console Intake commands: one plumbing, one rule (`IntakePolicy`).
  @intake_commands IntakePolicy.commands()

  # Commands only the `:system` actor (time-driven passes) may run.
  @system_commands [
    :send_due_batch,
    :reap_holds,
    :pass_payment_cutoff,
    :submit_refund,
    :reconcile,
    :finalise_attendance,
    :send_follow_ups,
    :import_carried_fee,
    :purge_retention,
    :alert_reply_waiting
  ]

  # The person's Intake-page commands (`{:intake_link, token}`).
  @intake_link_commands [:start_payment, :confirm]

  # ALE-411: the Reply Actions an Intake Reply may run. Never a forfeit:
  # `withdraw` must carry `refund: true` (`authorize_intake_reply/2`).
  @intake_reply_commands [
    :decline,
    :defer,
    :cancel_with_refund,
    :withdraw,
    :refund_carried_fee,
    :resend_link
  ]

  # Stripe-driven commands (webhooks and the success return).
  @stripe_commands [:complete_payment, :release_payment, :apply_refund_event]

  # Command → the family module that runs it (ALE-405). A console Intake
  # command (`{command, workshop_id, intake_id, attrs}`, `IntakePolicy`) is
  # routed by its shape first: `withdraw` and `refund_carried_fee` are also
  # the Waitlist tab's `{command, waitlist_id, attrs}` (`People`), and
  # `confirm` is also the person's own `:confirm` (`Payments`).
  @families %{
    schedule_workshop: Schedule,
    update_workshop: Schedule,
    reschedule_workshop: Schedule,
    cancel_workshop: Schedule,
    pause_batches: Schedule,
    resume_batches: Schedule,
    send_due_batch: Batches,
    fast_track: Batches,
    start_payment: Payments,
    confirm: Payments,
    complete_payment: Payments,
    release_payment: Payments,
    reap_holds: Payments,
    submit_refund: Refunds,
    apply_refund_event: Refunds,
    reconcile: Refunds,
    retry_refund: Refunds,
    record_manual_refund: Refunds,
    forfeit_carried_fee: Refunds,
    withdraw: People,
    refund_carried_fee: People,
    link_carried_fee_payment: People,
    delete_person: People,
    purge_retention: People,
    import_carried_fee: People,
    check_in: Attendance,
    undo_check_in: Attendance,
    pass_payment_cutoff: Attendance,
    finish_workshop: Attendance,
    finalise_attendance: Attendance,
    send_follow_ups: Attendance,
    invite: Attendance,
    set_staff: Staff,
    alert_reply_waiting: Replies
  }

  @doc """
  Executes one command as `actor`. The actor is authorized for the command
  before any read. Returns the command's closed view or a named refusal; a
  race never surfaces as an exception.
  """
  @spec execute(actor(), command(), keyword()) :: {:ok, term()} | {:error, error()}
  def execute(actor, command, opts \\ []) do
    with :ok <- authorize(actor, command) do
      run(actor, command, Clock.from_opts(opts))
    end
  end

  @doc "The transition table: entity → from status → legal target statuses."
  @spec transitions() :: %{atom() => %{String.t() => [String.t()]}}
  defdelegate transitions, to: Protocol

  @doc "Whether `from → to` is a legal status change for `entity`."
  @spec transition_allowed?(atom(), String.t(), String.t()) :: boolean()
  defdelegate transition_allowed?(entity, from, to), to: Protocol

  @doc "The lock levels, in the only order a command may take them."
  @spec lock_levels() :: [atom()]
  defdelegate lock_levels, to: Protocol

  @doc false
  # Constraint names `persist/1` translates; a test checks each one exists.
  @spec declared_constraints() :: [String.t()]
  defdelegate declared_constraints, to: Protocol

  @doc false
  # ALE-402 parity seam (`Commands.IntakeCommands`).
  @spec locked_intake_facts(binary(), binary(), Clock.t()) ::
          {:ok, IntakePolicy.t()} | {:error, term()}
  defdelegate locked_intake_facts(workshop_id, intake_id, clock), to: IntakeCommands

  @doc false
  # ALE-402 parity seam (`Commands.People`).
  @spec locked_carried_fee_facts(binary(), Clock.t()) ::
          {:ok, Dhc.BeginnersWorkshops.CarriedFeePolicy.t()} | {:error, term()}
  defdelegate locked_carried_fee_facts(waitlist_id, clock), to: People

  @doc false
  # ALE-417 parity seam (`Commands.People`).
  @spec locked_person_facts(binary(), Clock.t()) ::
          {:ok, Dhc.BeginnersWorkshops.PersonPolicy.t()} | {:error, term()}
  defdelegate locked_person_facts(waitlist_id, clock), to: People

  # ── Authorization ───────────────────────────────────────────────

  # `confirm` is both a console command and the person's own (ALE-388): the
  # Intake link actor takes the Intake-page path.
  defp authorize({:intake_link, _token} = actor, command) when command in @intake_link_commands,
    do: authorize_intake_link(actor)

  defp authorize({:intake_reply, _reply_id} = actor, command),
    do: authorize_intake_reply(actor, command)

  defp authorize(actor, command) do
    name = command_name(command)

    case Map.fetch(@staff_capabilities, name) do
      {:ok, capability} -> authorize_staff(actor, capability, command)
      :error when name in @system_commands -> authorize_system(actor)
      :error when name in @intake_link_commands -> authorize_intake_link(actor)
      :error when name in @stripe_commands -> authorize_stripe(actor)
      :error -> {:error, :unknown_command}
    end
  end

  defp authorize_system(:system), do: :ok
  defp authorize_system(_actor), do: {:error, :forbidden}

  # The link itself is the capability (ALE-374 "Intake link"): any
  # well-formed token may try; one that resolves to no Intake is `:not_found`.
  defp authorize_intake_link({:intake_link, token})
       when is_binary(token) and byte_size(token) in 1..128,
       do: :ok

  defp authorize_intake_link(_actor), do: {:error, :forbidden}

  # A recorded Intake Reply, asking for one of its Reply Actions; a
  # withdrawal only with its refund (a Reply Action never forfeits).
  defp authorize_intake_reply({:intake_reply, reply_id}, command) do
    with true <- command_name(command) in @intake_reply_commands,
         true <- refund_given?(command),
         {:ok, reply_id} <- Ecto.UUID.cast(reply_id),
         true <- Repo.exists?(from(r in IntakeReply, where: r.id == ^reply_id)) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp refund_given?(command) when is_tuple(command) and elem(command, 0) == :withdraw,
    do: command |> Tuple.to_list() |> List.last() |> refund_true?()

  defp refund_given?(_command), do: true

  defp refund_true?(%{} = attrs), do: Map.get(attrs, :refund, Map.get(attrs, "refund")) == true
  defp refund_true?(_attrs), do: false

  defp authorize_stripe(:stripe), do: :ok
  defp authorize_stripe(_actor), do: {:error, :forbidden}

  defp authorize_staff({:staff, principal_id}, capability, command)
       when is_binary(principal_id) do
    if Capabilities.assignment_scoped?(capability),
      do: authorize_assigned(principal_id, capability, elem(command, 1)),
      else: authorize_role(principal_id, capability)
  end

  defp authorize_staff(_actor, _capability, _command), do: {:error, :forbidden}

  defp authorize_role(principal_id, capability) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: id}),
         :ok <- Capabilities.authorize(projection, capability) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  # An assignment-scoped capability is decided against the workshop's Staff
  # rows only — the resource, read before anything the capability protects.
  # A denial conceals the workshop (`:not_found`, the door view's 404).
  # Public only so `Commands.Attendance` re-checks it under the workshop
  # lock (check-in, Finish); Reach keeps it inside the `Commands` namespace.
  @doc false
  @spec authorize_assigned(binary(), atom(), term()) :: :ok | {:error, :forbidden | :not_found}
  def authorize_assigned(principal_id, capability, workshop_id) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         {:ok, workshop_id} <- Ecto.UUID.cast(workshop_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: id}) do
      case Capabilities.authorize(projection, capability, staff_resource(workshop_id)) do
        :ok -> :ok
        {:error, :not_found} -> {:error, :not_found}
        {:error, _denied} -> {:error, :forbidden}
      end
    else
      :error -> {:error, :not_found}
      _ -> {:error, :forbidden}
    end
  end

  defp staff_resource(workshop_id) do
    %{
      assigned_principal_ids:
        Repo.all(
          from(s in StaffAssignment, where: s.workshop_id == ^workshop_id, select: s.principal_id)
        )
    }
  end

  defp command_name(command) when is_tuple(command), do: elem(command, 0)
  defp command_name(command) when is_atom(command), do: command
  defp command_name(_command), do: nil

  # ── Routing ─────────────────────────────────────────────────────

  defp run(actor, command, clock) do
    case family(command) do
      nil -> {:error, :unknown_command}
      family -> family.run(actor, command, clock)
    end
  end

  defp family({command, _workshop_id, _intake_id, _attrs}) when command in @intake_commands,
    do: IntakeCommands

  defp family(command), do: Map.get(@families, command_name(command))
end
