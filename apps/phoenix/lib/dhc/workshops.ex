defmodule Dhc.Workshops do
  @moduledoc """
  Workshop read-model helpers used by Phoenix API controllers.

  This is the prefactor slice for issue #143: complete the Ecto schema/query
  helper coverage for Workshops so later endpoint slices (member collection,
  coordinator calendar, attendee/refund management — PRD #142) can return
  domain-shaped DTOs using **Workshop** vocabulary rather than table-shaped
  `club_activity*` vocabulary.

  ## Vocabulary

  `club_activities` / `club_activity_interest` / `club_activity_registrations` /
  `club_activity_refunds` / `external_users` are **persistence** names only.
  The schemas in `Dhc.Workshops.*` map those tables, but every value returned
  from this module uses Workshop language: `Workshop`, `interest`,
  `registration`, `attendee`, `refund`, and a normalized `participant` DTO
  (`type: :member | :external`) instead of separate `user_profiles` /
  `external_users` join shapes. Controllers must not return the raw schemas;
  they return the maps built here.

  ## Authorization (RBAC) — read before reusing

  RBAC is enforced at the **router** layer (the `:workshops_manage`
  pipeline), not inside these helpers. Coordinator Workshop management reads
  (calendar, attendees, refunds) require the `workshops.manage` capability,
  whose role set lives only in `Dhc.Auth.Capabilities`.

  ### Historical registration RBAC drift — DO NOT MIRROR

  The original `club_activity_registrations` RLS policy
  (`20250715094450_workshop_registration_system.sql`, "Committee can view all
  registrations") granted **`beginners_coordinator`** full visibility of every
  member's Workshop registration. That was carried forward in the combined
  policy (`20250804190122_performance_fixes.sql`,
  `club_activity_registrations_access_policy`). This was **drift**, not intent:
  a beginners coordinator is not a Workshop coordinator and should never have
  seen all registrations.

  The fix (`20250923100806_fix_workshops_rls.sql`) corrected both the SELECT
  and UPDATE policies to `['admin', 'president', 'workshop_coordinator']`,
  removing `beginners_coordinator`. The Phoenix endpoints built on top of this
  module MUST require `workshops.manage` and MUST NOT reproduce the old
  `beginners_coordinator` access (`Dhc.Auth.CapabilitiesTest` pins it).

  ## Runtime behavior

  The helpers preserve the existing SvelteKit/PostgREST read behavior except
  where PRD #142 explicitly calls out a correction:

    * Attendees are registrations with `status` in `["confirmed", "pending"]`,
      ordered by `created_at` ascending (matches `RegistrationService
      .getWorkshopAttendees`).
    * Refunds are returned with no status filter, ordered by `requested_at`
      descending (matches `RefundService.getWorkshopRefunds`).
    * Registration counts are reported as separate **pending** and
      **confirmed** counts. The old coordinator calendar joined
      `club_activity_registrations` with no status filter and counted every row
      (including `cancelled`/`refunded`); PRD #142 corrects this to
      pending/confirmed. The member collection similarly moves from leaking
      individual attendee rows to a count, so members can see availability
      without seeing other attendees' identities.
    * The coordinator calendar DTO must NOT carry current-user registration
      data — that was a PostgREST join artifact (`user_registrations` in the
      SvelteKit query). Use `current_user_registration/2` only for the member
      collection, never for the coordinator calendar.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}
  alias Dhc.Destinations
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar

  alias Dhc.Workshops.{
    DestinationEnrichment,
    PaymentAttempt,
    PaymentCommands,
    Refund,
    RefundPolicy,
    RefundProjection,
    Registration,
    Workshop,
    WorkshopInterest
  }

  # ALE-181: attendee snapshot sentinel for a member registration whose
  # `member_user_id` resolves to no `user_profiles` row. The snapshot is
  # populated at write time, so a missing profile surfaces as a stable
  # sentinel instead of corrupting the read later.
  @unknown_member "[unknown member]"

  # Member-visible Workshop statuses (PRD #142): planned + published. Finished
  # and cancelled Workshops are not shown to members on the collection view.
  @member_visible_statuses ~w(planned published)

  # Registration statuses counted toward Workshop availability.
  @counted_registration_statuses ~w(pending confirmed)

  # ALE-181: the Workshop summary scalar field set, in one place. The list
  # read (`summary_query/0`) and the archived-Workshop body
  # (`archive_workshop/1`, via `build_summary/2`) both build maps with these
  # scalar keys plus three source counts (`interest_count`,
  # `pending_registration_count`, `confirmed_registration_count`) and the
  # capacity projection derived from those counts. The source counts are
  # passed into `build_summary/2` separately because each caller computes them
  # differently (a SQL aggregate for the list, the `registration_counts/1` +
  # `interest_count/1` helpers for the single archived read).
  @summary_scalar_fields ~w(id title description location destination_name destination_address
    directions_url start_date end_date max_capacity price_member price_non_member is_public
    refund_days status announce_discord announce_email created_by)a

  @doc """
  Returns the member-visible Workshop statuses (`planned`, `published`).
  """
  @spec member_visible_statuses() :: [String.t()]
  def member_visible_statuses, do: @member_visible_statuses

  @doc """
  Returns the attendee-snapshot sentinel used when a member registration's
  `member_user_id` resolves to no `user_profiles` row.

  Exposed so the test fixture (and any other consumer) references the same
  source of truth as the production write path. The migration carries its
  own copy of the literal because migrations cannot depend on application
  modules.
  """
  @spec unknown_member() :: String.t()
  def unknown_member, do: @unknown_member

  @doc """
  Lists the authenticated member's Workshop collection.

  The optional `status` query parameter is a comma-separated list that is
  constrained to the member-safe statuses (`planned`, `published`). Missing or
  empty `status` returns both visible statuses; unsafe/unknown statuses are
  dropped rather than rejected.
  """
  @spec list_member_workshops(binary(), map()) :: [map()]
  def list_member_workshops(user_id, params \\ %{}) when is_binary(user_id) and is_map(params) do
    statuses = member_status_filter(Map.get(params, "status"))
    summaries = list_workshop_summaries(statuses: statuses)

    # Batch the current-user state for the whole page in two queries instead
    # of two queries per Workshop (N+1).
    workshop_ids = Enum.map(summaries, & &1.id)
    interested_ids = interested_workshop_ids(workshop_ids, user_id)
    registrations = registrations_by_workshop(workshop_ids, user_id)

    Enum.map(summaries, fn workshop ->
      Map.merge(workshop, %{
        current_user_interest: MapSet.member?(interested_ids, workshop.id),
        current_user_registration: Map.get(registrations, workshop.id)
      })
    end)
  end

  # ── Workshop summaries ────────────────────────────────────────────────

  @doc """
  Lists Workshop summaries with interest and pending/confirmed registration
  counts.

  ## Options

    * `:statuses` — list of statuses to include (e.g. `["planned", "published"]`
      for the member collection).
    * `:exclude_statuses` — list of statuses to exclude (e.g. `["cancelled"]`
      for the coordinator calendar). Ignored when `:statuses` is set.
    * `:order_by` — field atom to order by (default `:start_date`).
    * `:order_direction` — `:asc` (default) or `:desc`.

  Counts are computed server-side so member-collection callers can show
  availability without exposing other attendees' identities. The summary never
  carries current-user registration data — use `current_user_registration/2`
  separately for the member collection only.
  """
  @spec list_workshop_summaries(keyword()) :: [map()]
  def list_workshop_summaries(opts \\ []) do
    order_field = Keyword.get(opts, :order_by, :start_date)
    direction = Keyword.get(opts, :order_direction, :asc)

    summary_query()
    |> apply_status_filter(Keyword.get(opts, :statuses), Keyword.get(opts, :exclude_statuses))
    |> apply_order(order_field, direction)
    |> Repo.all()
    |> Enum.map(&with_capacity_projection/1)
  end

  @doc """
  Fetches a single Workshop summary by id, or `nil` if no such Workshop.

  Returns the same shape as the entries in `list_workshop_summaries/1`.
  """
  @spec workshop_summary(binary()) :: map() | nil
  def workshop_summary(workshop_id) when is_binary(workshop_id) do
    summary =
      summary_query()
      |> where([w], w.id == ^workshop_id)
      |> Repo.one()

    if summary, do: with_capacity_projection(summary)
  end

  @doc """
  Returns the narrow Workshop source projection used by the committee Calendar
  integration, or `nil` when the Workshop no longer exists.

  Archived Workshops intentionally remain a Calendar source: archival hides a
  Workshop from dashboard reads, but does not alter its committee Calendar
  event. The projection deliberately excludes descriptions, notes, capacity,
  pricing, and attendee data.

  ALE-440: `location` is the recognizable Calendar location string — the
  manually entered destination name/address when one is stored, else the short
  venue label. It is never a link.
  """
  @spec calendar_projection(binary()) ::
          %{
            id: binary(),
            title: String.t(),
            status: String.t(),
            start_date: DateTime.t(),
            end_date: DateTime.t(),
            location: String.t()
          }
          | nil
  def calendar_projection(workshop_id) when is_binary(workshop_id) do
    from(w in Workshop,
      where: w.id == ^workshop_id,
      select: %{
        id: w.id,
        title: w.title,
        status: w.status,
        start_date: w.start_date,
        end_date: w.end_date,
        label: w.location,
        destination_name: w.destination_name,
        destination_address: w.destination_address
      }
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      source ->
        calendar_source(source)
    end
  end

  @doc """
  Returns Workshop ids a Calendar repair pass must reconcile.

  Upcoming Workshops remain sources after archival. Cancelled Workshops are
  included regardless of date so a delayed repair can still cancel a Calendar
  event after its source has passed.
  """
  @spec calendar_source_ids(DateTime.t()) :: [binary()]
  def calendar_source_ids(%DateTime{} = now) do
    from(w in Workshop,
      where: w.end_date > ^now or w.status == "cancelled",
      select: w.id
    )
    |> Repo.all()
  end

  @doc "Closed projections for the upcoming sources selected during Calendar launch."
  @spec calendar_launch_sources(DateTime.t()) :: [map()]
  def calendar_launch_sources(%DateTime{} = now) do
    from(w in Workshop,
      where: w.status != "cancelled" and w.start_date > ^now,
      order_by: [asc: w.start_date, asc: w.id],
      select: %{
        id: w.id,
        title: w.title,
        status: w.status,
        start_date: w.start_date,
        end_date: w.end_date,
        label: w.location,
        destination_name: w.destination_name,
        destination_address: w.destination_address
      }
    )
    |> Repo.all()
    |> Enum.map(&calendar_source/1)
  end

  # Keep the Calendar projection closed. The intermediate fields are selected only
  # to derive the native location and must never escape to the shared protocol.
  defp calendar_source(source) do
    %{
      id: source.id,
      title: source.title,
      status: source.status,
      start_date: source.start_date,
      end_date: source.end_date,
      location:
        Destinations.calendar_location(
          source.destination_name,
          source.destination_address,
          source.label
        )
    }
  end

  @doc "Current confirmed Workshop places and their saved registration addresses."
  @spec calendar_launch_places(binary()) :: [%{place_id: binary(), recipient: String.t() | nil}]
  def calendar_launch_places(workshop_id) when is_binary(workshop_id) do
    from(r in Registration,
      where: r.club_activity_id == ^workshop_id and r.status == "confirmed",
      order_by: [asc: r.id],
      select: %{place_id: r.id, recipient: r.email}
    )
    |> Repo.all()
  end

  @doc "Materializes Calendar launch intent through the Workshop write boundary."
  @spec materialize_calendar_launch(binary(), keyword()) ::
          :ok | {:error, :missing_end_time | :invalid_schedule}
  def materialize_calendar_launch(workshop_id, opts \\ []) when is_binary(workshop_id) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    case PaymentCommands.execute(:system, {:materialize_calendar_launch, workshop_id, clock}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Reviewed destination enrichment (ALE-443) ────────────────────────

  @doc """
  The closed facts (`Dhc.Workshops.DestinationEnrichment.facts/1`) of every
  Workshop that has not yet ended at `now`, for a reviewed destination
  backfill preview. Cancelled, archived and already-started Workshops are
  included so the preview can report why each is refused. Read-only.
  """
  @spec destination_backfill_sources(DateTime.t()) :: [DestinationEnrichment.facts()]
  def destination_backfill_sources(%DateTime{} = now) do
    from(w in Workshop, where: w.end_date > ^now, order_by: [asc: w.start_date, asc: w.id])
    |> Repo.all()
    |> Enum.map(&DestinationEnrichment.facts/1)
  end

  @doc """
  The advisory enrichment reading for one Workshop's facts: the same rule
  `enrich_destination/4` applies under the lock, without the reviewed-facts
  comparison.
  """
  @spec check_destination_enrichment(
          DestinationEnrichment.facts() | nil,
          DestinationEnrichment.destination(),
          DateTime.t()
        ) :: :change | :unchanged | {:refused, DestinationEnrichment.refusal()}
  defdelegate check_destination_enrichment(facts, proposed, now),
    to: DestinationEnrichment,
    as: :check

  @doc """
  Applies one reviewed same-Venue destination enrichment, including to a
  published Workshop outside the ordinary planned-only edit window.

  `actor` is `{:staff, principal_id}` and must hold `workshops.manage`; it is
  authorized before any read. Under the Workshop lock the row is re-read and
  judged by `DestinationEnrichment.check_reviewed/4` against the clock read
  inside the lock (`opts[:clock]`, default `DateTime.utc_now/0`): the start
  must still be in the future and the label, Dublin schedule, status and
  destination must still be the reviewed `expected` facts. Only the three
  destination fields change; the label, schedule and every place, payment and
  refund fact stay as they are, and no email is queued. A change records the
  identifier-only Calendar intent in the same transaction; an unchanged
  destination writes nothing.
  """
  @spec enrich_destination(
          {:staff, binary()},
          binary(),
          %{
            expected: DestinationEnrichment.expected(),
            destination: DestinationEnrichment.destination()
          },
          keyword()
        ) ::
          {:ok, :changed | :unchanged}
          | {:error, :forbidden | :invalid_destination | DestinationEnrichment.refusal()}
  def enrich_destination(actor, workshop_id, review, opts \\ [])

  def enrich_destination(
        actor,
        workshop_id,
        %{expected: expected, destination: destination},
        opts
      )
      when is_binary(workshop_id) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    with :ok <- authorize_manager(actor),
         {:ok, id} <- cast_workshop_id(workshop_id) do
      {:ok, result} =
        Repo.transaction(fn ->
          workshop = Repo.one(from(w in Workshop, where: w.id == ^id, lock: "FOR UPDATE"))
          facts = workshop && DestinationEnrichment.facts(workshop)

          facts
          |> DestinationEnrichment.check_reviewed(expected, destination, clock.())
          |> enrich_locked(workshop, destination)
        end)

      result
    end
  end

  defp enrich_locked(:unchanged, _workshop, _destination), do: {:ok, :unchanged}
  defp enrich_locked({:refused, reason}, _workshop, _destination), do: {:error, reason}

  defp enrich_locked(:change, workshop, destination) do
    case workshop |> Workshop.destination_changeset(destination) |> Repo.update() do
      {:ok, updated} ->
        :ok = WorkshopCalendar.record_change(:workshop, updated.id)
        {:ok, :changed}

      {:error, %Ecto.Changeset{}} ->
        {:error, :invalid_destination}
    end
  end

  # The CLI operator is a staff principal, judged like a dashboard session:
  # an active profile whose roles grant `workshops.manage`.
  defp authorize_manager({:staff, principal_id}) when is_binary(principal_id) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: id}),
         :ok <- Capabilities.authorize(projection, :"workshops.manage") do
      :ok
    else
      _denied -> {:error, :forbidden}
    end
  end

  defp authorize_manager(_actor), do: {:error, :forbidden}

  defp cast_workshop_id(workshop_id) do
    case Ecto.UUID.cast(workshop_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # ── Counts ────────────────────────────────────────────────────────────

  @doc """
  Returns the number of members who have expressed interest in a Workshop.
  """
  @spec interest_count(binary()) :: non_neg_integer()
  def interest_count(workshop_id) when is_binary(workshop_id) do
    from(i in WorkshopInterest, where: i.club_activity_id == ^workshop_id, select: count(i.id))
    |> Repo.one()
  end

  @doc """
  Returns pending and confirmed registration counts for a Workshop.

  These are the statuses that count toward Workshop availability (PRD #142).
  `cancelled` and `refunded` registrations are excluded.
  """
  @spec registration_counts(binary()) :: %{
          pending: non_neg_integer(),
          confirmed: non_neg_integer()
        }
  def registration_counts(workshop_id) when is_binary(workshop_id) do
    from(r in Registration,
      where: r.club_activity_id == ^workshop_id,
      select: %{
        pending: fragment("count(*) FILTER (WHERE ? = 'pending')", r.status),
        confirmed: fragment("count(*) FILTER (WHERE ? = 'confirmed')", r.status)
      }
    )
    |> Repo.one()
    |> case do
      nil -> %{pending: 0, confirmed: 0}
      counts -> counts
    end
  end

  @doc """
  Returns confirmed Registration ids that currently hold participant Calendar
  places for a Workshop.

  This deliberately exposes neither attendee rows nor participant data. Pending
  registrations never receive an invitation, and attendance or archival does
  not affect a confirmed place.
  """
  @spec calendar_place_ids(binary()) :: [binary()]
  def calendar_place_ids(workshop_id) when is_binary(workshop_id) do
    from(r in Registration,
      where: r.club_activity_id == ^workshop_id and r.status == "confirmed",
      order_by: [asc: r.id],
      select: r.id
    )
    |> Repo.all()
  end

  @doc """
  Projects active Registration capacity facts from a Workshop summary.

  Pending and confirmed Registrations are the source counts. Remaining places
  are clamped at zero for defensive over-capacity data. A `nil` maximum means
  the Workshop is uncapped, so remaining places stay `nil` and capacity is
  never reported as reached.
  """
  @spec capacity_projection(map()) :: %{
          registration_count: non_neg_integer(),
          places_remaining: non_neg_integer() | nil,
          is_at_capacity: boolean()
        }
  def capacity_projection(%{
        max_capacity: max_capacity,
        pending_registration_count: pending_count,
        confirmed_registration_count: confirmed_count
      }) do
    registration_count = pending_count + confirmed_count

    %{
      registration_count: registration_count,
      places_remaining: places_remaining(max_capacity, registration_count),
      is_at_capacity: not is_nil(max_capacity) and registration_count >= max_capacity
    }
  end

  # ── Current-user state ────────────────────────────────────────────────

  @doc """
  Returns whether a member (by Supabase auth user id) has expressed interest
  in a Workshop.
  """
  @spec current_user_interest?(binary(), binary()) :: boolean()
  def current_user_interest?(workshop_id, user_id)
      when is_binary(workshop_id) and is_binary(user_id) do
    from(
      i in WorkshopInterest,
      where: i.club_activity_id == ^workshop_id and i.user_id == ^user_id
    )
    |> Repo.exists?()
  end

  @doc """
  Toggles the current member's interest in a planned Workshop.

  `user_id` is always the Supabase auth user id from the validated JWT. Returns
  a small command-result DTO for the member UI instead of leaking the underlying
  `club_activity_interest` row shape.
  """
  @spec toggle_interest(binary(), binary()) ::
          {:ok, %{interested: boolean(), action: String.t(), message: String.t()}}
          | {:error, :not_found | :not_planned}
  def toggle_interest(workshop_id, user_id) when is_binary(workshop_id) and is_binary(user_id) do
    Repo.transaction(fn ->
      case Repo.get(Workshop, workshop_id) do
        nil ->
          Repo.rollback(:not_found)

        %Workshop{status: status} when status != "planned" ->
          Repo.rollback(:not_planned)

        %Workshop{} ->
          toggle_planned_interest(workshop_id, user_id)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the current member's registration for a Workshop, or `nil`.

  `user_id` is the member's Supabase auth user id (which is what
  `club_activity_registrations.member_user_id` stores, via the
  `user_profiles.supabase_user_id` foreign key).

  The registration is returned regardless of status (`pending`, `confirmed`,
  `cancelled`, `refunded`) so the member collection endpoint can derive both
  "am I registered" and "was I refunded" state. A unique constraint guarantees
  at most one registration row per member per Workshop.
  """
  @spec current_user_registration(binary(), binary()) ::
          %{id: binary(), status: String.t()} | nil
  def current_user_registration(workshop_id, user_id)
      when is_binary(workshop_id) and is_binary(user_id) do
    from(r in Registration,
      where: r.club_activity_id == ^workshop_id and r.member_user_id == ^user_id,
      select: %{id: r.id, status: r.status},
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Creates a Stripe PaymentIntent for the authenticated member's Workshop registration.

  The member id is always derived from the session Principal. The PaymentIntent
  is bound to the Stripe Customer read **from the member's own User Profile**
  inside the boundary; the caller's `customerId` is accepted for wire
  compatibility but never used, so a member cannot start a payment attached to
  another member's Customer. Capacity and duplicate active-registration checks
  happen before Stripe is called, preserving the existing SvelteKit member-registration gate behavior.
  """
  @spec create_member_payment_intent(binary(), binary(), map()) ::
          {:ok, %{client_secret: String.t(), payment_intent_id: String.t()}}
          | {:error,
             :not_found
             | :not_published
             | :already_registered
             | :full
             | :invalid_amount
             | :payment_failed}
  def create_member_payment_intent(workshop_id, user_id, _attrs)
      when is_binary(workshop_id) and is_binary(user_id) do
    PaymentCommands.execute(
      {:member, user_id},
      {:start_member_payment, workshop_id}
    )
  end

  @doc """
  Completes an authenticated member Workshop registration after Stripe payment.

  Stripe's PaymentIntent must be `succeeded` and must carry metadata tying it to
  the requested Workshop and member. Completion is idempotent for the same
  PaymentIntent id. If capacity is exhausted after payment but before insert, a
  durable compensating Refund is recorded and `:compensation_pending` is returned.
  """
  @spec complete_member_registration(binary(), binary(), binary()) ::
          {:ok, Registration.t()}
          | {:error,
             :not_found
             | :not_published
             | :already_registered
             | :full
             | :compensation_pending
             | :payment_not_completed
             | :payment_metadata_mismatch
             | :payment_failed}
  def complete_member_registration(workshop_id, user_id, payment_intent_id)
      when is_binary(workshop_id) and is_binary(user_id) and is_binary(payment_intent_id) do
    PaymentCommands.execute(
      {:member, user_id},
      {:complete_member_payment, workshop_id, payment_intent_id}
    )
  end

  @doc """
  Returns the public external-registration gate state for a Workshop.
  """
  @spec external_registration_gate(binary()) :: map()
  def external_registration_gate(workshop_id) when is_binary(workshop_id) do
    case Repo.get(Workshop, workshop_id) do
      nil ->
        %{can_register: false, reason: "NOT_FOUND"}

      %Workshop{archived_at: %DateTime{}} ->
        %{can_register: false, reason: "NOT_FOUND"}

      %Workshop{status: status} when status != "published" ->
        %{can_register: false, reason: "NOT_PUBLISHED"}

      %Workshop{is_public: false} ->
        %{can_register: false, reason: "NOT_PUBLIC"}

      %Workshop{price_non_member: price} when is_nil(price) or price < 0 ->
        %{can_register: false, reason: "NO_EXTERNAL_PRICE"}

      %Workshop{} = workshop ->
        if active_registration_count(workshop_id) >= workshop.max_capacity do
          %{can_register: false, reason: "FULL"}
        else
          %{can_register: true, workshop: external_registration_workshop(workshop)}
        end
    end
  end

  @doc """
  Creates an embedded Stripe Checkout Session for a public Workshop.
  """
  @spec create_external_checkout_session(binary(), binary(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found | :full | :invalid_return_url | :payment_failed}
  def create_external_checkout_session(workshop_id, payment_attempt_id, return_url)
      when is_binary(workshop_id) and is_binary(payment_attempt_id) and is_binary(return_url) do
    PaymentCommands.execute(
      :external,
      {:start_external_payment, workshop_id, payment_attempt_id, return_url}
    )
  end

  @doc """
  Completes an external registration from a paid Stripe Checkout Session.

  The Workshop row is locked before the final capacity check so concurrent
  completions serialize. A paid attendee who loses the final place is refunded.
  """
  @spec complete_external_registration(binary(), String.t()) ::
          {:ok, Registration.t()}
          | {:error,
             :not_found
             | :checkout_session_not_found
             | :already_registered
             | :compensation_pending
             | :payment_not_completed
             | :payment_metadata_mismatch
             | :customer_details_missing
             | :payment_failed}
  def complete_external_registration(workshop_id, checkout_session_id)
      when is_binary(workshop_id) and is_binary(checkout_session_id) do
    PaymentCommands.execute(
      :external,
      {:complete_external_payment, workshop_id, checkout_session_id}
    )
  end

  @doc """
  Cancels the current member's active Workshop registration.

  Refund eligibility is decided under the Workshop and Registration locks: an
  eligible Registration is refunded, any other is cancelled without a Refund.
  """
  @spec cancel_member_registration(binary(), binary()) ::
          {:ok, %{registration: Registration.t(), refund_pending: boolean()}}
          | {:error, :not_found}
  def cancel_member_registration(workshop_id, user_id)
      when is_binary(workshop_id) and is_binary(user_id) do
    PaymentCommands.execute({:member, user_id}, {:cancel_member_registration, workshop_id})
  end

  @doc """
  Returns a registration when it is eligible for a refund.

  Advisory: it reads without locks, so the answer can be stale, but it uses
  the same `Dhc.Workshops.RefundPolicy` rule as the locked Refund command.
  """
  @spec refund_eligibility(binary()) :: {:ok, Registration.t()} | {:error, atom()}
  def refund_eligibility(registration_id) when is_binary(registration_id) do
    row =
      from(r in Registration,
        as: :registration,
        join: w in Workshop,
        on: w.id == r.club_activity_id,
        where: r.id == ^registration_id,
        select: %{
          registration: r,
          workshop: w,
          refund_requested?:
            exists(from(rf in Refund, where: rf.registration_id == parent_as(:registration).id))
        }
      )
      |> Repo.one()

    facts = row || %{registration: nil, workshop: nil, refund_requested?: false}

    with :ok <- RefundPolicy.requested_refund(facts, DateTime.utc_now()) do
      {:ok, row.registration}
    end
  end

  @doc """
  Records a durable Refund obligation for a registration and enqueues its
  submission; the Registration becomes `refunded`.
  """
  @spec process_refund(binary(), binary(), String.t(), binary()) ::
          {:ok, Refund.t()} | {:error, atom()}
  def process_refund(workshop_id, registration_id, reason, requested_by)
      when is_binary(workshop_id) and is_binary(registration_id) and is_binary(reason) and
             is_binary(requested_by) do
    with {:ok, %{refund: refund}} <-
           request_refund(workshop_id, registration_id, reason, requested_by) do
      {:ok, refund}
    end
  end

  @doc """
  Same command as `process_refund/4`, returning the Refund in the
  `list_workshop_refunds/1` projection so callers need no second read.
  """
  @spec refund_registration(binary(), binary(), String.t(), binary()) ::
          {:ok, RefundProjection.t()} | {:error, atom()}
  def refund_registration(workshop_id, registration_id, reason, requested_by)
      when is_binary(workshop_id) and is_binary(registration_id) and is_binary(reason) and
             is_binary(requested_by) do
    with {:ok, %{view: view}} <-
           request_refund(workshop_id, registration_id, reason, requested_by) do
      {:ok, view}
    end
  end

  defp request_refund(workshop_id, registration_id, reason, requested_by) do
    PaymentCommands.execute(
      {:coordinator, requested_by},
      {:request_refund, workshop_id, registration_id, reason}
    )
  end

  @doc """
  Applies a Stripe `refund.*` event object to its Refund.

  Unknown refunds are acknowledged; a Refund in a terminal status never
  changes, so late or replayed events are ignored.
  """
  @spec apply_stripe_refund_event(map()) ::
          :ok | {:error, :invalid_refund_object | :retry_exhausted | atom()}
  def apply_stripe_refund_event(object) when is_map(object) do
    with {:ok, _outcome} <- PaymentCommands.execute(:system, {:apply_refund_update, object}) do
      :ok
    end
  end

  # ── Attendees & refunds ───────────────────────────────────────────────

  @doc """
  Lists attendee records for a Workshop with normalized participant identity.

  Matches the existing runtime read (`RegistrationService.getWorkshopAttendees`):
  registrations with `status` in `["confirmed", "pending"]`, ordered by
  `created_at` ascending. Each attendee carries a normalized `participant` DTO
  (`type: :member | :external`, `display_name`, `email`) instead of separate
  `user_profiles` / `external_users` join shapes.
  """
  @spec list_workshop_attendees(binary()) :: [map()]
  def list_workshop_attendees(workshop_id) when is_binary(workshop_id) do
    # ALE-181: read the attendee snapshot (`display_name`, `email`) from the
    # registration row, not a live join to `user_profiles`/`external_users`.
    # The `member_user_id`/`external_user_id` columns still drive the
    # `participant.type` so a member with a missing profile name resolves
    # to `:member` rather than `:external`.
    from(r in Registration,
      where: r.club_activity_id == ^workshop_id and r.status in @counted_registration_statuses,
      order_by: [asc: r.created_at],
      select: %{
        id: r.id,
        status: r.status,
        attendance_status: r.attendance_status,
        attendance_marked_at: r.attendance_marked_at,
        attendance_marked_by: r.attendance_marked_by,
        attendance_notes: r.attendance_notes,
        amount_paid: r.amount_paid,
        currency: r.currency,
        registered_at: r.registered_at,
        confirmed_at: r.confirmed_at,
        cancelled_at: r.cancelled_at,
        registration_notes: r.registration_notes,
        member_user_id: r.member_user_id,
        external_user_id: r.external_user_id,
        display_name: r.display_name,
        email: r.email
      }
    )
    |> Repo.all()
    |> Enum.map(&to_attendee/1)
  end

  @doc """
  Lists refund records for a Workshop with normalized participant identity.

  Matches the existing runtime read (`RefundService.getWorkshopRefunds`): all
  refunds for the Workshop's registrations (no status filter), ordered by
  `requested_at` descending. Each refund carries a normalized `participant` DTO
  reached through its registration, instead of exposing the storage join.
  """
  @spec list_workshop_refunds(binary()) :: [RefundProjection.t()]
  def list_workshop_refunds(workshop_id) when is_binary(workshop_id) do
    # ALE-181: participant identity is read from the registration snapshot
    # (`display_name`, `email`), not a live join. ALE-340: rows go through
    # the same projection the Refund commands return.
    from(rf in Refund,
      inner_join: r in Registration,
      on: r.id == rf.registration_id,
      where: r.club_activity_id == ^workshop_id,
      order_by: [desc: rf.requested_at],
      select: {rf, r}
    )
    |> Repo.all()
    |> Enum.map(fn {refund, registration} -> RefundProjection.project(refund, registration) end)
  end

  @doc """
  Returns the combined attendee/refund management payload for a Workshop.

  Mirrors the coordinator attendee page loader
  (`dashboard/workshops/[id]/attendees/+page.server.ts`), which loads the
  Workshop summary, attendees, and refunds together. `workshop` is `nil` when
  the Workshop does not exist so the future endpoint can return 404.
  """
  @spec workshop_attendees_and_refunds(binary()) ::
          %{workshop: map() | nil, attendees: [map()], refunds: [map()]}
  def workshop_attendees_and_refunds(workshop_id) when is_binary(workshop_id) do
    %{
      workshop: workshop_summary(workshop_id),
      attendees: list_workshop_attendees(workshop_id),
      refunds: list_workshop_refunds(workshop_id)
    }
  end

  @doc """
  Atomically records coordinator attendance updates for active Workshop attendees.

  Attendance can only be marked once the Workshop has started. Every update in
  the batch must target a pending or confirmed registration belonging to that
  Workshop; otherwise no registrations are changed.
  """
  @spec update_workshop_attendance(binary(), binary(), [map()]) ::
          {:ok, [Registration.t()]}
          | {:error, :not_found | :not_started | :invalid_attendee | :invalid_updates}
  def update_workshop_attendance(workshop_id, marked_by, updates)
      when is_binary(workshop_id) and is_binary(marked_by) and is_list(updates) do
    Repo.transaction(fn -> update_workshop_attendance_locked(workshop_id, marked_by, updates) end)
    |> case do
      {:ok, registrations} -> {:ok, registrations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_workshop_attendance_locked(workshop_id, marked_by, updates) do
    with :ok <- ensure_attendance_updates_present(updates),
         %Workshop{} = workshop <-
           Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE")),
         :ok <- ensure_workshop_started(workshop),
         :ok <- ensure_unique_attendance_registration_ids(updates),
         {:ok, registrations} <- active_attendance_registrations(workshop_id, updates) do
      persist_attendance_updates(updates, registrations, marked_by)
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_attendance_updates(updates, registrations, marked_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.map(updates, fn update ->
      registration = Map.fetch!(registrations, update.registration_id)

      registration
      |> Ecto.Changeset.change(%{
        attendance_status: update.attendance_status,
        attendance_notes: update.notes,
        attendance_marked_at: now,
        attendance_marked_by: marked_by
      })
      |> Repo.update!()
    end)
  end

  # ── Management lifecycle ──────────────────────────────────────────────

  @doc """
  Creates a planned Workshop management row.

  `created_by` is always taken from the authenticated coordinator/admin user id,
  never from client input. Status starts as `planned`; lifecycle transitions use
  `publish_workshop/1` and `cancel_workshop/1`.
  """
  @spec create_workshop(map(), binary()) :: {:ok, Workshop.t()} | {:error, Ecto.Changeset.t()}
  def create_workshop(attrs, created_by) when is_map(attrs) and is_binary(created_by) do
    Repo.transaction(fn ->
      with {:ok, workshop} <-
             %Workshop{created_by: created_by, status: "planned"}
             |> Workshop.management_changeset(attrs)
             |> Repo.insert(),
           :ok <- WorkshopCalendar.record_change(:workshop, workshop.id) do
        workshop
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Updates Workshop management fields.

  General edits are planned-only. Pricing-only edits preserve the existing
  looser rule approved in ALE-118: pricing may also be changed after publish as
  long as there are zero active (`pending`/`confirmed`) registrations.
  """
  @spec update_workshop(binary(), map()) ::
          {:ok, Workshop.t()}
          | {:error, :not_found | :not_editable | :pricing_locked | Ecto.Changeset.t()}
  def update_workshop(workshop_id, attrs) when is_binary(workshop_id) and is_map(attrs) do
    Repo.transaction(fn ->
      with %Workshop{} = workshop <-
             Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE")),
           :ok <- authorize_update(workshop, attrs),
           {:ok, updated} <- workshop |> Workshop.management_changeset(attrs) |> Repo.update(),
           :ok <- WorkshopCalendar.record_change(:workshop, updated.id) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Deletes or archives a Workshop.

  ALE-181 rewrite. The gate is registrations-existence, not status: a Workshop
  with any registration history is soft-deleted (archived) so its financial and
  audit rows are retained permanently (the financial-tail FKs are RESTRICT); a
  Workshop with no registrations is hard-deleted. The previous status gate
  (`planned`-only) is dropped.

  ## Returns

    * `{:ok, :archived, workshop}` — the Workshop had registrations and was
      soft-deleted (`archived_at` set). The controller returns `200` with the
      archived Workshop summary body.
    * `{:ok, :deleted}` — the Workshop had no registrations and was
      hard-deleted. The controller returns `204`.
    * `{:error, :already_archived}` — the Workshop was already archived.
      The controller returns `409`.
    * `{:error, :not_found}` — no such Workshop. The controller returns
      `404`.
  """
  @spec delete_workshop(binary()) ::
          {:ok, :archived, map()}
          | {:ok, :deleted}
          | {:error, :not_found | :already_archived}
  def delete_workshop(workshop_id) when is_binary(workshop_id) do
    {:ok, result} =
      Repo.transaction(fn -> delete_workshop_locked(workshop_id) end)

    result
  end

  defp delete_workshop_locked(workshop_id) do
    workshop = Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))

    case workshop do
      nil -> {:error, :not_found}
      %Workshop{archived_at: %DateTime{}} -> {:error, :already_archived}
      %Workshop{} = workshop -> delete_or_archive_workshop(workshop)
    end
  end

  defp delete_or_archive_workshop(workshop) do
    if has_registrations?(workshop.id) do
      archive_workshop(workshop)
    else
      :ok = WorkshopCalendar.record_deleted(:workshop, workshop.id)
      {:ok, _} = Repo.delete(workshop)
      {:ok, :deleted}
    end
  end

  defp has_registrations?(workshop_id) do
    Repo.exists?(from(r in Registration, where: r.club_activity_id == ^workshop_id)) or
      Repo.exists?(from(pa in PaymentAttempt, where: pa.club_activity_id == ^workshop_id))
  end

  # ALE-181: archive a Workshop by stamping `archived_at`. Returns the
  # archived Workshop summary body so the controller can render `200`
  # directly. The body is built via `build_summary/2` (not via
  # `workshop_summary/1`, which filters archived Workshops out) — counts
  # reuse the existing `registration_counts/1` and `interest_count/1`
  # helpers.
  defp archive_workshop(workshop) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, archived} =
      workshop
      |> Ecto.Changeset.change(archived_at: now)
      |> Repo.update()

    counts = registration_counts(workshop.id)

    summary =
      build_summary(archived, %{
        interest_count: interest_count(workshop.id),
        pending_registration_count: counts.pending,
        confirmed_registration_count: counts.confirmed
      })

    {:ok, :archived, summary}
  end

  @doc """
  Publishes a planned Workshop.
  """
  @spec publish_workshop(binary()) ::
          {:ok, Workshop.t()} | {:error, :not_found | :not_publishable}
  def publish_workshop(workshop_id) when is_binary(workshop_id) do
    transition_workshop(workshop_id, "planned", "published", :not_publishable)
  end

  @doc """
  Cancels a published Workshop and creates traceable refund attempts for every
  active paid registration. Refund eligibility deadlines do not apply when the
  club cancels the Workshop.

  The status change and the Refund fan-out run under one Workshop lock in
  `Dhc.Workshops.PaymentCommands`. `:already_requested` means a Refund for one
  of the Registrations was recorded outside that lock; nothing was changed and
  the cancellation can be retried.
  """
  @spec cancel_workshop(binary(), binary() | nil) ::
          {:ok, Workshop.t()} | {:error, :not_found | :not_cancellable | :already_requested}
  def cancel_workshop(workshop_id, requested_by \\ nil) when is_binary(workshop_id) do
    # Without a requesting coordinator nobody is recorded as asking for the
    # Refunds, so the system cancels and leaves Registrations as they are.
    {actor, registrations} =
      if requested_by, do: {{:coordinator, requested_by}, :refund_owed}, else: {:system, :keep}

    PaymentCommands.execute(
      actor,
      {:cancel_workshop, workshop_id, &mark_workshop_cancelled/1, registrations}
    )
  end

  defp mark_workshop_cancelled(%Workshop{status: "published"} = workshop) do
    with {:ok, cancelled} <-
           workshop |> Ecto.Changeset.change(status: "cancelled") |> Repo.update(),
         :ok <- WorkshopCalendar.record_change(:workshop, cancelled.id) do
      {:ok, cancelled}
    end
  end

  defp mark_workshop_cancelled(%Workshop{}), do: {:error, :not_cancellable}

  # ── Private: summary query ────────────────────────────────────────────

  defp authorize_update(%Workshop{status: "planned"}, _attrs), do: :ok

  defp authorize_update(%Workshop{} = workshop, attrs) do
    cond do
      attrs == %{} ->
        :ok

      pricing_only?(attrs) && active_registration_count(workshop.id) == 0 ->
        :ok

      pricing_only?(attrs) ->
        {:error, :pricing_locked}

      true ->
        {:error, :not_editable}
    end
  end

  defp ensure_attendance_updates_present([]), do: {:error, :invalid_updates}
  defp ensure_attendance_updates_present(_updates), do: :ok

  defp ensure_workshop_started(%Workshop{start_date: start_date}) do
    if DateTime.compare(start_date, DateTime.utc_now()) in [:lt, :eq],
      do: :ok,
      else: {:error, :not_started}
  end

  defp ensure_unique_attendance_registration_ids(updates) do
    registration_ids = Enum.map(updates, & &1.registration_id)

    if length(registration_ids) == length(Enum.uniq(registration_ids)),
      do: :ok,
      else: {:error, :invalid_attendee}
  end

  defp active_attendance_registrations(workshop_id, updates) do
    registration_ids = Enum.map(updates, & &1.registration_id)

    registrations =
      from(r in Registration,
        where:
          r.club_activity_id == ^workshop_id and r.status in @counted_registration_statuses and
            r.id in ^registration_ids,
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    if map_size(registrations) == length(registration_ids),
      do: {:ok, registrations},
      else: {:error, :invalid_attendee}
  end

  defp pricing_only?(attrs) do
    attrs
    |> Map.keys()
    |> Enum.all?(&(&1 in [:price_member, :price_non_member]))
  end

  defp active_registration_count(workshop_id) do
    from(r in Registration,
      where: r.club_activity_id == ^workshop_id and r.status in @counted_registration_statuses,
      select: count(r.id)
    )
    |> Repo.one()
  end

  defp external_registration_workshop(%Workshop{} = workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      start_date: workshop.start_date,
      end_date: workshop.end_date,
      location: workshop.location,
      destination_name: workshop.destination_name,
      destination_address: workshop.destination_address,
      directions_url: workshop.directions_url,
      price_non_member: trunc(workshop.price_non_member),
      max_capacity: workshop.max_capacity
    }
  end

  defp transition_workshop(workshop_id, from_status, to_status, invalid_reason) do
    Repo.transaction(fn ->
      case Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        %Workshop{status: ^from_status} = workshop ->
          transitioned = workshop |> Ecto.Changeset.change(status: to_status) |> Repo.update!()
          :ok = WorkshopCalendar.record_change(:workshop, transitioned.id)
          transitioned

        %Workshop{} ->
          Repo.rollback(invalid_reason)
      end
    end)
  end

  defp toggle_planned_interest(workshop_id, user_id) do
    existing =
      from(i in WorkshopInterest,
        where: i.club_activity_id == ^workshop_id and i.user_id == ^user_id,
        limit: 1
      )
      |> Repo.one()

    case existing do
      %WorkshopInterest{} = interest ->
        {:ok, _} = Repo.delete(interest)

        %{
          interested: false,
          action: "withdrawn",
          message: "Interest withdrawn successfully"
        }

      nil ->
        {:ok, _interest} =
          %WorkshopInterest{club_activity_id: workshop_id, user_id: user_id}
          |> Repo.insert()

        %{
          interested: true,
          action: "expressed",
          message: "Interest expressed successfully"
        }
    end
  end

  # ALE-181: build a summary map from a `Workshop` struct plus its three
  # counts. Shared by `archive_workshop/1` (the archived-Workshop body, which
  # cannot use `workshop_summary/1` because that read filters archived rows
  # out) so the archived body stays the same shape as the list summary
  # without duplicating the field list.
  defp build_summary(%Workshop{} = workshop, counts) do
    workshop
    |> Map.take(@summary_scalar_fields)
    |> Map.merge(counts)
    |> with_capacity_projection()
  end

  defp with_capacity_projection(summary) do
    Map.merge(summary, capacity_projection(summary))
  end

  defp places_remaining(nil, _registration_count), do: nil

  defp places_remaining(max_capacity, registration_count) do
    max(max_capacity - registration_count, 0)
  end

  defp summary_query do
    # ALE-181: exclude archived (soft-deleted) Workshops from summaries so
    # they drop out of the member collection and coordinator calendar
    # without losing their financial/audit rows.
    #
    # The `select` field set mirrors `@summary_scalar_fields` +
    # `@summary_count_fields` (the same shape `build_summary/2` builds for
    # the archived-Workshop body). The SQL select names each field
    # explicitly against its binding because Ecto's `select` needs literal
    # field references, not a `Map.take`; keep the two in sync when adding a
    # summary field.
    #
    # Counts are correlated subqueries instead of a `left_join` pair: joining
    # interests × registrations produced an I × R cartesian product per
    # Workshop that `count(DISTINCT) FILTER` then had to collapse. Each
    # subquery scans only its own index range.
    interest_count =
      from(i in WorkshopInterest,
        where: i.club_activity_id == parent_as(:workshop).id,
        select: count(i.id)
      )

    pending_count =
      from(r in Registration,
        where: r.club_activity_id == parent_as(:workshop).id and r.status == "pending",
        select: count(r.id)
      )

    confirmed_count =
      from(r in Registration,
        where: r.club_activity_id == parent_as(:workshop).id and r.status == "confirmed",
        select: count(r.id)
      )

    from(w in Workshop,
      as: :workshop,
      where: is_nil(w.archived_at),
      select: %{
        id: w.id,
        title: w.title,
        description: w.description,
        location: w.location,
        destination_name: w.destination_name,
        destination_address: w.destination_address,
        directions_url: w.directions_url,
        start_date: w.start_date,
        end_date: w.end_date,
        max_capacity: w.max_capacity,
        price_member: w.price_member,
        price_non_member: w.price_non_member,
        is_public: w.is_public,
        refund_days: w.refund_days,
        status: w.status,
        announce_discord: w.announce_discord,
        announce_email: w.announce_email,
        created_by: w.created_by,
        interest_count: subquery(interest_count),
        pending_registration_count: subquery(pending_count),
        confirmed_registration_count: subquery(confirmed_count)
      }
    )
  end

  defp apply_status_filter(query, nil, nil), do: query

  defp apply_status_filter(query, statuses, _exclude) when is_list(statuses) do
    where(query, [w], w.status in ^statuses)
  end

  defp apply_status_filter(query, nil, exclude) when is_list(exclude) do
    where(query, [w], w.status not in ^exclude)
  end

  # `order_by` is split by direction so the keyword-list form (`asc:`/`desc:`)
  # stays literal — the 2-arity tuple-list form with a pinned direction does
  # not bind named bindings. `w` is the 0th binding (Workshop) from
  # `summary_query/0`.
  defp apply_order(query, field, :asc), do: order_by(query, [w], asc: field(w, ^field))
  defp apply_order(query, field, :desc), do: order_by(query, [w], desc: field(w, ^field))

  defp member_status_filter(nil), do: @member_visible_statuses
  defp member_status_filter(""), do: @member_visible_statuses

  defp member_status_filter(status) when is_binary(status) do
    status
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&(&1 in @member_visible_statuses))
    |> Enum.uniq()
  end

  # Batched variants of `current_user_interest?/2` /
  # `current_user_registration/2` for the member collection: one query per
  # page instead of one per Workshop.
  defp interested_workshop_ids([], _user_id), do: MapSet.new()

  defp interested_workshop_ids(workshop_ids, user_id) do
    from(i in WorkshopInterest,
      where: i.club_activity_id in ^workshop_ids and i.user_id == ^user_id,
      select: i.club_activity_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp registrations_by_workshop([], _user_id), do: %{}

  defp registrations_by_workshop(workshop_ids, user_id) do
    from(r in Registration,
      where: r.club_activity_id in ^workshop_ids and r.member_user_id == ^user_id,
      select: {r.club_activity_id, %{id: r.id, status: r.status}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── Private: participant normalization ────────────────────────────────

  defp to_attendee(row) do
    %{
      id: row.id,
      status: row.status,
      attendance_status: row.attendance_status,
      attendance_marked_at: row.attendance_marked_at,
      attendance_marked_by: row.attendance_marked_by,
      attendance_notes: row.attendance_notes,
      amount_paid: row.amount_paid,
      currency: row.currency,
      registered_at: row.registered_at,
      confirmed_at: row.confirmed_at,
      cancelled_at: row.cancelled_at,
      registration_notes: row.registration_notes,
      participant: participant(row)
    }
  end

  # ALE-181: participant identity is read from the registration's attendee
  # snapshot (`display_name`, `email`), not a live join to
  # `user_profiles`/`external_users`. The source-of-truth FK column
  # (`member_user_id` vs `external_user_id`) still drives the `type` so a
  # member with a missing profile name resolves to `:member` rather than
  # `:external`.
  defp participant(%{member_user_id: nil, external_user_id: ext_id} = row)
       when not is_nil(ext_id) do
    %{
      type: :external,
      display_name: row.display_name,
      email: row.email
    }
  end

  defp participant(%{member_user_id: member_id} = row) when not is_nil(member_id) do
    %{
      type: :member,
      display_name: row.display_name,
      email: row.email
    }
  end
end
