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

  @workshop_registration_metadata_type "workshop_registration"
  @member_registration_actor_type "member"

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

  The member id is always derived from the Supabase JWT `sub` by the controller.
  Capacity and duplicate active-registration checks happen before Stripe is
  called, preserving the existing SvelteKit member-registration gate behavior.
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
  def create_member_payment_intent(workshop_id, user_id, attrs)
      when is_binary(workshop_id) and is_binary(user_id) and is_map(attrs) do
    amount = Map.get(attrs, "amount") || Map.get(attrs, :amount)
    currency = Map.get(attrs, "currency") || Map.get(attrs, :currency) || "eur"
    customer_id = Map.get(attrs, "customerId") || Map.get(attrs, :customer_id)

    with {:ok, amount} <- normalize_positive_integer(amount),
         {:ok, workshop} <- member_registration_workshop(workshop_id),
         :ok <- ensure_no_active_member_registration(workshop_id, user_id),
         :ok <- ensure_workshop_capacity(workshop_id, workshop.max_capacity),
         {:ok, payment_intent} <-
           stripe_create_payment_intent(%{
             amount: amount,
             currency: currency,
             customer_id: customer_id,
             workshop_id: workshop_id,
             workshop_title: workshop.title,
             user_id: user_id
           }) do
      {:ok,
       %{
         client_secret: Map.fetch!(payment_intent, "client_secret"),
         payment_intent_id: Map.fetch!(payment_intent, "id")
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Completes an authenticated member Workshop registration after Stripe payment.

  Stripe's PaymentIntent must be `succeeded` and must carry metadata tying it to
  the requested Workshop and member. Completion is idempotent for the same
  PaymentIntent id. If capacity is exhausted after payment but before insert, a
  best-effort refund is issued and `:full` is returned.
  """
  @spec complete_member_registration(binary(), binary(), binary()) ::
          {:ok, Registration.t()}
          | {:error,
             :not_found
             | :not_published
             | :already_registered
             | :full
             | :payment_not_completed
             | :payment_metadata_mismatch
             | :payment_failed}
  def complete_member_registration(workshop_id, user_id, payment_intent_id)
      when is_binary(workshop_id) and is_binary(user_id) and is_binary(payment_intent_id) do
    with {:ok, payment_intent} <- stripe_retrieve_payment_intent(payment_intent_id),
         :ok <- validate_member_payment_intent(payment_intent, workshop_id, user_id),
         {:ok, registration} <-
           Repo.transaction(fn ->
             case Repo.get_by(Registration, stripe_checkout_session_id: payment_intent_id) do
               %Registration{} = registration ->
                 registration

               nil ->
                 with {:ok, workshop} <- member_registration_workshop(workshop_id),
                      :ok <- ensure_no_active_member_registration(workshop_id, user_id),
                      :ok <- ensure_workshop_capacity(workshop_id, workshop.max_capacity) do
                   insert_member_registration(workshop_id, user_id, payment_intent)
                 else
                   {:error, :full} ->
                     _ = stripe_refund_payment_intent(payment_intent_id)
                     Repo.rollback(:full)

                   {:error, reason} ->
                     Repo.rollback(reason)
                 end
             end
           end) do
      {:ok, registration}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels the current member's active Workshop registration.
  """
  @spec cancel_member_registration(binary(), binary()) ::
          {:ok, %{registration: Registration.t(), refund_processed: boolean()}}
          | {:error, :not_found}
  def cancel_member_registration(workshop_id, user_id)
      when is_binary(workshop_id) and is_binary(user_id) do
    registration =
      from(r in Registration,
        where:
          r.club_activity_id == ^workshop_id and r.member_user_id == ^user_id and
            r.status in @counted_registration_statuses,
        limit: 1
      )
      |> Repo.one()

    case registration do
      nil ->
        {:error, :not_found}

      %Registration{} = registration ->
        case refund_eligibility(registration.id) do
          {:ok, _registration} ->
            case process_refund(
                   workshop_id,
                   registration.id,
                   "Member cancelled registration",
                   user_id
                 ) do
              {:ok, refund} ->
                {:ok,
                 %{
                   registration: Repo.get!(Registration, registration.id),
                   refund_processed: refund.status in ["processing", "completed", "pending"]
                 }}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, _ineligible_reason} ->
            {:ok, updated} =
              registration
              |> Ecto.Changeset.change(
                status: "cancelled",
                cancelled_at: DateTime.utc_now() |> DateTime.truncate(:second)
              )
              |> Repo.update()

            {:ok, %{registration: updated, refund_processed: false}}
        end
    end
  end

  @doc """
  Returns a registration when it is eligible for a refund.
  """
  @spec refund_eligibility(binary()) :: {:ok, Registration.t()} | {:error, atom()}
  def refund_eligibility(registration_id) when is_binary(registration_id) do
    row =
      from(r in Registration,
        join: w in Workshop,
        on: w.id == r.club_activity_id,
        where: r.id == ^registration_id,
        select: %{
          registration: r,
          workshop_status: w.status,
          start_date: w.start_date,
          refund_days: w.refund_days
        }
      )
      |> Repo.one()

    cond do
      is_nil(row) ->
        {:error, :registration_not_found}

      row.registration.status == "refunded" ->
        {:error, :already_refunded}

      row.workshop_status == "finished" ->
        {:error, :workshop_finished}

      not is_integer(row.registration.amount_paid) or row.registration.amount_paid <= 0 ->
        {:error, :not_paid}

      refund_deadline_passed?(row.start_date, row.refund_days) ->
        {:error, :deadline_passed}

      Repo.exists?(from(rf in Refund, where: rf.registration_id == ^registration_id)) ->
        {:error, :already_requested}

      true ->
        {:ok, row.registration}
    end
  end

  @doc """
  Creates a traceable refund attempt and asks Stripe to refund a registration.
  """
  @spec process_refund(binary(), binary(), String.t(), binary(), keyword()) ::
          {:ok, Refund.t()} | {:error, atom()}
  def process_refund(workshop_id, registration_id, reason, requested_by, opts \\ [])
      when is_binary(workshop_id) and is_binary(registration_id) and is_binary(reason) and
             is_binary(requested_by) do
    eligibility =
      if Keyword.get(opts, :skip_eligibility, false),
        do: registration_for_refund(workshop_id, registration_id),
        else: refund_eligibility(registration_id)

    with {:ok, %Registration{club_activity_id: ^workshop_id} = registration} <- eligibility,
         {:ok, refund} <- create_refund_attempt(registration, reason, requested_by) do
      submit_refund(refund, registration, requested_by)
    else
      {:ok, %Registration{}} -> {:error, :registration_not_found}
      {:error, reason} -> {:error, reason}
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
    Repo.transaction(fn ->
      with :ok <- ensure_attendance_updates_present(updates),
           %Workshop{} = workshop <-
             Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE")),
           :ok <- ensure_workshop_started(workshop),
           :ok <- ensure_unique_attendance_registration_ids(updates),
           {:ok, registrations} <- active_attendance_registrations(workshop_id, updates) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        updates
        |> Enum.map(fn update ->
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
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, registrations} -> {:ok, registrations}
      {:error, reason} -> {:error, reason}
    end
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
    %Workshop{created_by: created_by, status: "planned"}
    |> Workshop.management_changeset(attrs)
    |> Repo.insert()
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
    with %Workshop{} = workshop <- Repo.get(Workshop, workshop_id),
         :ok <- authorize_update(workshop, attrs) do
      workshop
      |> Workshop.management_changeset(attrs)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a planned Workshop.
  """
  @spec delete_workshop(binary()) :: :ok | {:error, :not_found | :not_deletable}
  def delete_workshop(workshop_id) when is_binary(workshop_id) do
    case Repo.get(Workshop, workshop_id) do
      nil ->
        {:error, :not_found}

      %Workshop{status: "planned"} = workshop ->
        {:ok, _} = Repo.delete(workshop)
        :ok

      %Workshop{} ->
        {:error, :not_deletable}
    end
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
  """
  @spec cancel_workshop(binary()) :: {:ok, Workshop.t()} | {:error, :not_found | :not_cancellable}
  def cancel_workshop(workshop_id, requested_by \\ nil) when is_binary(workshop_id) do
    with {:ok, workshop} <-
           transition_workshop(workshop_id, "published", "cancelled", :not_cancellable) do
      if is_binary(requested_by) do
        workshop_id
        |> active_paid_registrations()
        |> Enum.each(fn registration ->
          _ =
            process_refund(
              workshop_id,
              registration.id,
              "Workshop cancelled",
              requested_by,
              skip_eligibility: true
            )
        end)
      end

      {:ok, workshop}
    end
  end

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

  defp member_registration_workshop(workshop_id) do
    case Repo.get(Workshop, workshop_id) do
      nil -> {:error, :not_found}
      %Workshop{status: status} when status != "published" -> {:error, :not_published}
      %Workshop{} = workshop -> {:ok, workshop}
    end
  end

  defp ensure_no_active_member_registration(workshop_id, user_id) do
    exists? =
      from(r in Registration,
        where:
          r.club_activity_id == ^workshop_id and r.member_user_id == ^user_id and
            r.status in @counted_registration_statuses
      )
      |> Repo.exists?()

    if exists?, do: {:error, :already_registered}, else: :ok
  end

  defp ensure_workshop_capacity(workshop_id, max_capacity) do
    if active_registration_count(workshop_id) >= max_capacity do
      {:error, :full}
    else
      :ok
    end
  end

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_positive_integer(value) when is_float(value) and value > 0 do
    {:ok, trunc(value)}
  end

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {amount, ""} when amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp normalize_positive_integer(_), do: {:error, :invalid_amount}

  defp insert_member_registration(workshop_id, user_id, payment_intent) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Registration{
      club_activity_id: workshop_id,
      member_user_id: user_id,
      status: "confirmed",
      stripe_checkout_session_id: Map.fetch!(payment_intent, "id"),
      amount_paid: Map.get(payment_intent, "amount"),
      currency: Map.get(payment_intent, "currency", "eur"),
      confirmed_at: now,
      registered_at: now
    }
    |> Repo.insert!()
  end

  defp validate_member_payment_intent(payment_intent, workshop_id, user_id) do
    metadata = Map.get(payment_intent, "metadata", %{}) || %{}

    cond do
      Map.get(payment_intent, "status") != "succeeded" ->
        {:error, :payment_not_completed}

      metadata["type"] != @workshop_registration_metadata_type or
        metadata["actor_type"] != @member_registration_actor_type or
        metadata["workshop_id"] != workshop_id or metadata["user_id"] != user_id ->
        {:error, :payment_metadata_mismatch}

      true ->
        :ok
    end
  end

  defp stripe_create_payment_intent(args) do
    form =
      [
        {:amount, args.amount},
        {:currency, args.currency},
        {"metadata[type]", @workshop_registration_metadata_type},
        {"metadata[workshop_id]", args.workshop_id},
        {"metadata[workshop_title]", args.workshop_title},
        {"metadata[user_id]", args.user_id},
        {"metadata[actor_type]", @member_registration_actor_type},
        {"automatic_payment_methods[enabled]", "false"},
        {"payment_method_types[]", "card"},
        {"payment_method_types[]", "link"}
      ]
      |> maybe_put_customer(args.customer_id)

    case stripe_client().request(method: :post, url: "/v1/payment_intents", body: form) do
      {:ok, %{"id" => _id, "client_secret" => _secret} = body} -> {:ok, body}
      {:ok, _body} -> {:error, :payment_failed}
      {:error, _reason} -> {:error, :payment_failed}
    end
  end

  defp stripe_retrieve_payment_intent(payment_intent_id) do
    case stripe_client().request(method: :get, url: "/v1/payment_intents/#{payment_intent_id}") do
      {:ok, %{"id" => _id} = body} -> {:ok, body}
      {:ok, _body} -> {:error, :payment_failed}
      {:error, _reason} -> {:error, :payment_failed}
    end
  end

  defp stripe_refund_payment_intent(payment_intent_id) do
    stripe_client().request(
      method: :post,
      url: "/v1/refunds",
      body: [payment_intent: payment_intent_id, reason: "duplicate"]
    )
  end

  defp refund_deadline_passed?(_start_date, nil), do: false

  defp refund_deadline_passed?(start_date, refund_days) do
    deadline = DateTime.add(start_date, -refund_days, :day)
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  defp registration_for_refund(workshop_id, registration_id) do
    case Repo.get_by(Registration, id: registration_id, club_activity_id: workshop_id) do
      nil -> {:error, :registration_not_found}
      registration -> {:ok, registration}
    end
  end

  defp create_refund_attempt(registration, reason, requested_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Refund{
      registration_id: registration.id,
      refund_amount: registration.amount_paid,
      refund_reason: reason,
      status: "pending",
      requested_at: now,
      requested_by: requested_by,
      stripe_payment_intent_id: registration.stripe_checkout_session_id
    }
    |> Repo.insert()
  end

  defp submit_refund(refund, %Registration{stripe_checkout_session_id: nil} = registration, _by) do
    mark_registration_refunded(registration)
    {:ok, refund}
  end

  defp submit_refund(refund, registration, processed_by) do
    body = [
      payment_intent: registration.stripe_checkout_session_id,
      amount: registration.amount_paid,
      reason: "requested_by_customer"
    ]

    case stripe_client().request(method: :post, url: "/v1/refunds", body: body) do
      {:ok, %{"id" => stripe_refund_id}} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok, updated_refund} =
          refund
          |> Ecto.Changeset.change(
            status: "processing",
            stripe_refund_id: stripe_refund_id,
            stripe_payment_intent_id: registration.stripe_checkout_session_id,
            processed_at: now,
            processed_by: processed_by
          )
          |> Repo.update()

        mark_registration_refunded(registration)
        {:ok, updated_refund}

      _error ->
        refund
        |> Ecto.Changeset.change(status: "failed")
        |> Repo.update!()

        {:error, :refund_failed}
    end
  end

  defp mark_registration_refunded(registration) do
    registration
    |> Ecto.Changeset.change(status: "refunded")
    |> Repo.update!()
  end

  defp active_paid_registrations(workshop_id) do
    from(r in Registration,
      where:
        r.club_activity_id == ^workshop_id and r.status in @counted_registration_statuses and
          r.amount_paid > 0
    )
    |> Repo.all()
  end

  defp maybe_put_customer(form, nil), do: form
  defp maybe_put_customer(form, ""), do: form
  defp maybe_put_customer(form, customer_id), do: [{:customer, customer_id} | form]

  defp stripe_client do
    Application.get_env(:dhc, :workshop_stripe_client, Dhc.Stripe.Client)
  end

  defp transition_workshop(workshop_id, from_status, to_status, invalid_reason) do
    case Repo.get(Workshop, workshop_id) do
      nil ->
        {:error, :not_found}

      %Workshop{status: ^from_status} = workshop ->
        workshop
        |> Ecto.Changeset.change(status: to_status)
        |> Repo.update()

      %Workshop{} ->
        {:error, invalid_reason}
    end
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
