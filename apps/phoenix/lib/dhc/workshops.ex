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

  RBAC is enforced at the **controller** layer (mirroring the Waitlist and
  Members read migrations), not inside these helpers. The intended Phoenix RBAC
  for coordinator Workshop management reads (calendar, attendees, refunds) is:

      @coordinator_management_roles ~w(workshop_coordinator president admin)

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
  module MUST use `@coordinator_management_roles` above and MUST NOT reproduce
  the old `beginners_coordinator` access. If you add a coordinator Workshop
  read, authorize against `workshop_coordinator`, `president`, and `admin`
  only.

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

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Workshops.{ExternalUser, Registration, Refund, Workshop, WorkshopInterest}

  # The canonical Phoenix RBAC for coordinator Workshop management reads
  # (calendar + attendees/refunds). Mirrors the corrected RLS roles from
  # `20250923100806_fix_workshops_rls.sql`. Future controllers should reference
  # this list — NOT the old `beginners_coordinator` policy (see moduledoc).
  @coordinator_management_roles ~w(workshop_coordinator president admin)

  # Member-visible Workshop statuses (PRD #142): planned + published. Finished
  # and cancelled Workshops are not shown to members on the collection view.
  @member_visible_statuses ~w(planned published)

  # Registration statuses counted toward Workshop availability.
  @counted_registration_statuses ~w(pending confirmed)

  @doc """
  Returns the canonical coordinator Workshop management roles.

  Exposed so future controller authorization plugs build against the same
  source of truth as this context, and so tests can assert the drift has not
  been reintroduced (`beginners_coordinator` is NOT a member).
  """
  @spec coordinator_management_roles() :: [String.t()]
  def coordinator_management_roles, do: @coordinator_management_roles

  @doc """
  Returns the member-visible Workshop statuses (`planned`, `published`).
  """
  @spec member_visible_statuses() :: [String.t()]
  def member_visible_statuses, do: @member_visible_statuses

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

    [statuses: statuses]
    |> list_workshop_summaries()
    |> Enum.map(&with_current_user_state(&1, user_id))
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
  end

  @doc """
  Fetches a single Workshop summary by id, or `nil` if no such Workshop.

  Returns the same shape as the entries in `list_workshop_summaries/1`.
  """
  @spec workshop_summary(binary()) :: map() | nil
  def workshop_summary(workshop_id) when is_binary(workshop_id) do
    summary_query()
    |> where([w], w.id == ^workshop_id)
    |> Repo.one()
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
    from(r in Registration,
      left_join: p in UserProfile,
      on: p.supabase_user_id == r.member_user_id,
      left_join: eu in ExternalUser,
      on: eu.id == r.external_user_id,
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
        member_first_name: p.first_name,
        member_last_name: p.last_name,
        external_first_name: eu.first_name,
        external_last_name: eu.last_name,
        external_email: eu.email
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
  @spec list_workshop_refunds(binary()) :: [map()]
  def list_workshop_refunds(workshop_id) when is_binary(workshop_id) do
    from(rf in Refund,
      inner_join: r in Registration,
      on: r.id == rf.registration_id,
      left_join: p in UserProfile,
      on: p.supabase_user_id == r.member_user_id,
      left_join: eu in ExternalUser,
      on: eu.id == r.external_user_id,
      where: r.club_activity_id == ^workshop_id,
      order_by: [desc: rf.requested_at],
      select: %{
        id: rf.id,
        registration_id: rf.registration_id,
        refund_amount: rf.refund_amount,
        refund_reason: rf.refund_reason,
        status: rf.status,
        stripe_refund_id: rf.stripe_refund_id,
        requested_at: rf.requested_at,
        processed_at: rf.processed_at,
        completed_at: rf.completed_at,
        member_user_id: r.member_user_id,
        external_user_id: r.external_user_id,
        member_first_name: p.first_name,
        member_last_name: p.last_name,
        external_first_name: eu.first_name,
        external_last_name: eu.last_name,
        external_email: eu.email
      }
    )
    |> Repo.all()
    |> Enum.map(&to_refund/1)
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

  # ── Private: summary query ────────────────────────────────────────────

  defp summary_query do
    from(w in Workshop,
      left_join: i in WorkshopInterest,
      on: i.club_activity_id == w.id,
      left_join: r in Registration,
      on: r.club_activity_id == w.id,
      group_by: w.id,
      select: %{
        id: w.id,
        title: w.title,
        description: w.description,
        location: w.location,
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
        # `count(DISTINCT) FILTER` keeps the counts correct despite the
        # interest × registration cartesian product from the double join.
        interest_count: count(i.id, :distinct),
        pending_registration_count:
          fragment("count(DISTINCT ?) FILTER (WHERE ? = 'pending')", r.id, r.status),
        confirmed_registration_count:
          fragment("count(DISTINCT ?) FILTER (WHERE ? = 'confirmed')", r.id, r.status)
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

  defp with_current_user_state(workshop, user_id) do
    Map.merge(workshop, %{
      current_user_interest: current_user_interest?(workshop.id, user_id),
      current_user_registration: current_user_registration(workshop.id, user_id)
    })
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

  defp to_refund(row) do
    %{
      id: row.id,
      registration_id: row.registration_id,
      refund_amount: row.refund_amount,
      refund_reason: row.refund_reason,
      status: row.status,
      stripe_refund_id: row.stripe_refund_id,
      requested_at: row.requested_at,
      processed_at: row.processed_at,
      completed_at: row.completed_at,
      participant: participant(row)
    }
  end

  # Branch on the source-of-truth FK column, not on the joined names, so a
  # member with a missing profile name still resolves to `:member`.
  defp participant(%{member_user_id: nil, external_user_id: ext_id} = row)
       when not is_nil(ext_id) do
    %{
      type: :external,
      display_name: "#{row.external_first_name} #{row.external_last_name}",
      email: row.external_email
    }
  end

  defp participant(%{member_user_id: member_id} = row) when not is_nil(member_id) do
    %{
      type: :member,
      display_name: "#{row.member_first_name} #{row.member_last_name}",
      email: nil
    }
  end
end
