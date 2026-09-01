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

  alias Dhc.Auth.Principal
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  alias Dhc.Workshops.{
    ExternalUser,
    PaymentAttempt,
    Registration,
    Refund,
    Workshop,
    WorkshopInterest
  }

  # ALE-181: attendee snapshot sentinel for a member registration whose
  # `member_user_id` resolves to no `user_profiles` row. The snapshot is
  # populated at write time, so a missing profile surfaces as a stable
  # sentinel instead of corrupting the read later.
  @unknown_member "[unknown member]"

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
  @external_registration_actor_type "external"

  # ALE-181: the Workshop summary scalar field set, in one place. The list
  # read (`summary_query/0`) and the archived-Workshop body
  # (`archive_workshop/1`, via `build_summary/2`) both build maps with these
  # scalar keys plus three source counts (`interest_count`,
  # `pending_registration_count`, `confirmed_registration_count`) and the
  # capacity projection derived from those counts. The source counts are
  # passed into `build_summary/2` separately because each caller computes them
  # differently (a SQL aggregate for the list, the `registration_counts/1` +
  # `interest_count/1` helpers for the single archived read).
  @summary_scalar_fields ~w(id title description location start_date end_date lock_version
    max_capacity price_member price_non_member is_public refund_days status
    announce_discord announce_email created_by)a

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
      select: %{id: r.id, status: r.status, lock_version: r.lock_version},
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
    customer_id = Map.get(attrs, "customerId") || Map.get(attrs, :customer_id)

    with {:ok, attempt, workshop} <- durable_member_payment_attempt(workshop_id, user_id),
         {:ok, payment_intent} <- ensure_member_payment_intent(attempt, workshop, customer_id) do
      {:ok,
       %{
         client_secret: Map.fetch!(payment_intent, "client_secret"),
         payment_intent_id: Map.fetch!(payment_intent, "id")
       }}
    end
  end

  defp durable_member_payment_attempt(workshop_id, user_id) do
    Repo.transaction(fn -> durable_member_payment_attempt_locked(workshop_id, user_id) end)
    |> case do
      {:ok, {attempt, workshop}} -> {:ok, attempt, workshop}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_member_payment_attempt_locked(workshop_id, user_id) do
    case lock_existing_member_payment_attempt(workshop_id, user_id) do
      %PaymentAttempt{} = attempt ->
        {attempt, Repo.get!(Workshop, workshop_id)}

      nil ->
        create_member_payment_attempt(workshop_id, user_id)
    end
  end

  defp lock_existing_member_payment_attempt(workshop_id, user_id) do
    Repo.one(
      from(pa in PaymentAttempt,
        where:
          pa.club_activity_id == ^workshop_id and pa.member_user_id == ^user_id and
            pa.actor_type == "member" and pa.status in ["pending", "paid"],
        lock: "FOR UPDATE"
      )
    )
  end

  defp create_member_payment_attempt(workshop_id, user_id) do
    with {:ok, workshop} <- member_registration_workshop_for_update(workshop_id),
         :ok <- ensure_no_active_member_registration(workshop_id, user_id),
         :ok <- ensure_workshop_capacity(workshop_id, workshop.max_capacity),
         {:ok, amount} <- normalize_positive_integer(workshop.price_member) do
      attempt =
        Repo.insert!(%PaymentAttempt{
          club_activity_id: workshop_id,
          member_user_id: user_id,
          actor_type: "member",
          amount: amount,
          currency: "eur",
          status: "pending"
        })

      {attempt, workshop}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_member_payment_intent(
         %PaymentAttempt{stripe_payment_intent_id: id},
         _workshop,
         _customer_id
       )
       when is_binary(id) do
    case stripe_adapter().retrieve_payment_intent(id) do
      {:ok, %{"id" => ^id, "client_secret" => secret} = payment_intent}
      when is_binary(secret) ->
        {:ok, payment_intent}

      _ ->
        {:error, :payment_failed}
    end
  end

  defp ensure_member_payment_intent(attempt, workshop, customer_id) do
    params = %{
      amount: attempt.amount,
      currency: attempt.currency,
      customer_id: customer_id,
      workshop_id: workshop.id,
      workshop_title: workshop.title,
      user_id: attempt.member_user_id,
      idempotency_key: "workshop-payment-attempt:#{attempt.id}"
    }

    case stripe_adapter().create_payment_intent(params) do
      {:ok, %{"id" => id, "client_secret" => secret} = payment_intent}
      when is_binary(id) and is_binary(secret) ->
        attempt
        |> Ecto.Changeset.change(stripe_payment_intent_id: id)
        |> Repo.update!()

        {:ok, payment_intent}

      _ ->
        {:error, :payment_failed}
    end
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
             | :payment_not_completed
             | :payment_metadata_mismatch
             | :payment_failed}
  def complete_member_registration(workshop_id, user_id, payment_intent_id)
      when is_binary(workshop_id) and is_binary(user_id) and is_binary(payment_intent_id) do
    with {:ok, payment_intent} <- stripe_retrieve_payment_intent(payment_intent_id),
         :ok <- validate_member_payment_intent(payment_intent, workshop_id, user_id),
         {:ok, attempt} <-
           load_or_recover_member_attempt(workshop_id, user_id, payment_intent),
         :ok <- validate_payment_attempt_amount(attempt, payment_intent),
         {:ok, %Registration{} = registration} <-
           complete_member_registration_transaction(
             workshop_id,
             user_id,
             payment_intent_id,
             payment_intent,
             attempt
           ) do
      {:ok, registration}
    else
      {:ok, {:compensation_pending, _refund}} -> {:error, :compensation_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_member_registration_transaction(
         workshop_id,
         user_id,
         payment_intent_id,
         payment_intent,
         attempt
       ) do
    Repo.transaction(fn ->
      attempt =
        Repo.one!(from(pa in PaymentAttempt, where: pa.id == ^attempt.id, lock: "FOR UPDATE"))

      complete_locked_member_registration(
        workshop_id,
        user_id,
        payment_intent_id,
        payment_intent,
        attempt
      )
    end)
  end

  defp complete_locked_member_registration(
         workshop_id,
         user_id,
         payment_intent_id,
         payment_intent,
         attempt
       ) do
    case existing_member_registration(attempt.id, payment_intent_id) do
      %Registration{} = registration ->
        registration

      nil ->
        complete_unregistered_member(workshop_id, user_id, payment_intent, attempt)
    end
  end

  defp existing_member_registration(attempt_id, payment_intent_id) do
    Repo.get_by(Registration, payment_attempt_id: attempt_id) ||
      Repo.get_by(Registration, stripe_payment_intent_id: payment_intent_id)
  end

  defp complete_unregistered_member(workshop_id, user_id, payment_intent, attempt) do
    case Repo.get_by(Refund, payment_attempt_id: attempt.id) do
      %Refund{} = refund ->
        {:compensation_pending, refund}

      nil ->
        register_paid_member(workshop_id, user_id, payment_intent, attempt)
    end
  end

  defp register_paid_member(workshop_id, user_id, payment_intent, attempt) do
    with {:ok, workshop} <- member_registration_workshop_for_update(workshop_id),
         :ok <- ensure_no_active_member_registration(workshop_id, user_id),
         :ok <- ensure_workshop_capacity(workshop_id, workshop.max_capacity) do
      registration = insert_member_registration(workshop_id, user_id, payment_intent, attempt)
      mark_member_attempt_registered!(attempt)
      registration
    else
      {:error, reason} -> handle_member_registration_error(attempt, reason)
    end
  end

  defp mark_member_attempt_registered!(attempt) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attempt
    |> Ecto.Changeset.change(status: "registered", paid_at: now, concluded_at: now)
    |> Repo.update!()
  end

  defp handle_member_registration_error(attempt, :full) do
    refund = create_compensating_refund!(attempt, "Workshop capacity exhausted")
    {:compensation_pending, refund}
  end

  defp handle_member_registration_error(attempt, reason)
       when reason in [:not_found, :not_published] do
    refund = create_compensating_refund!(attempt, "Workshop unavailable")
    {:compensation_pending, refund}
  end

  defp handle_member_registration_error(_attempt, reason), do: Repo.rollback(reason)

  defp create_compensating_refund!(attempt, reason, payment_intent_id \\ nil) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    refund =
      Repo.insert!(%Refund{
        id: id,
        payment_attempt_id: attempt.id,
        refund_amount: attempt.amount,
        refund_reason: reason,
        status: "pending",
        stripe_payment_intent_id: payment_intent_id || attempt.stripe_payment_intent_id,
        idempotency_key: "workshop-refund:#{id}",
        requested_at: now
      })

    refund.id
    |> then(&Dhc.Workshops.Workers.RefundWorker.new(%{refund_id: &1}))
    |> Oban.insert!()

    attempt
    |> Ecto.Changeset.change(
      status: "compensating",
      paid_at: attempt.paid_at || now,
      concluded_at: now
    )
    |> Repo.update!()

    refund
  end

  defp load_or_recover_member_attempt(workshop_id, user_id, payment_intent) do
    payment_intent_id = Map.fetch!(payment_intent, "id")

    Repo.transaction(fn ->
      workshop =
        Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

      case Repo.get_by(PaymentAttempt, stripe_payment_intent_id: payment_intent_id) do
        %PaymentAttempt{
          club_activity_id: ^workshop_id,
          member_user_id: ^user_id,
          actor_type: "member"
        } = attempt ->
          attempt

        %PaymentAttempt{} ->
          Repo.rollback(:payment_metadata_mismatch)

        nil ->
          recover_member_attempt(workshop, user_id, payment_intent_id)
      end
    end)
    |> case do
      {:ok, attempt} -> {:ok, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_member_attempt(workshop, user_id, payment_intent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.one(
           from(pa in PaymentAttempt,
             where:
               pa.club_activity_id == ^workshop.id and pa.member_user_id == ^user_id and
                 pa.actor_type == "member" and pa.status in ["pending", "paid"],
             lock: "FOR UPDATE"
           )
         ) do
      %PaymentAttempt{stripe_payment_intent_id: nil} = attempt ->
        attempt
        |> Ecto.Changeset.change(
          status: "paid",
          stripe_payment_intent_id: payment_intent_id,
          paid_at: now
        )
        |> Repo.update!()

      %PaymentAttempt{} ->
        Repo.rollback(:payment_metadata_mismatch)

      nil ->
        Repo.insert!(%PaymentAttempt{
          club_activity_id: workshop.id,
          member_user_id: user_id,
          actor_type: "member",
          amount: trunc(workshop.price_member),
          currency: "eur",
          status: "paid",
          stripe_payment_intent_id: payment_intent_id,
          paid_at: now
        })
    end
  end

  defp validate_payment_attempt_amount(attempt, payment_intent) do
    amount = Map.get(payment_intent, "amount") || Map.get(payment_intent, "amount_total")

    if amount == attempt.amount and
         String.downcase(Map.get(payment_intent, "currency", "")) == attempt.currency do
      :ok
    else
      attempt
      |> Ecto.Changeset.change(status: "policy_failed")
      |> Repo.update!()

      {:error, :payment_metadata_mismatch}
    end
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
    with true <- String.contains?(return_url, "{CHECKOUT_SESSION_ID}"),
         {:ok, attempt, workshop} <-
           durable_external_payment_attempt(workshop_id, payment_attempt_id),
         {:ok, checkout_session} <-
           ensure_external_checkout_session(attempt, workshop, return_url) do
      case Map.get(checkout_session, "client_secret") do
        secret when is_binary(secret) and secret != "" ->
          {:ok,
           %{
             checkout_session_id: Map.fetch!(checkout_session, "id"),
             checkout_client_secret: secret,
             checkout_url: Map.get(checkout_session, "url")
           }}

        _ ->
          {:error, :payment_failed}
      end
    else
      false -> {:error, :invalid_return_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_external_payment_attempt(workshop_id, payment_attempt_id) do
    Repo.transaction(fn ->
      durable_external_payment_attempt_locked(workshop_id, payment_attempt_id)
    end)
    |> case do
      {:ok, {attempt, workshop}} -> {:ok, attempt, workshop}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_external_payment_attempt_locked(workshop_id, payment_attempt_id) do
    workshop = Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))

    case Repo.get(PaymentAttempt, payment_attempt_id) do
      %PaymentAttempt{club_activity_id: ^workshop_id, actor_type: "external"} = attempt ->
        {attempt, workshop}

      %PaymentAttempt{} ->
        Repo.rollback(:payment_failed)

      nil ->
        create_external_payment_attempt(workshop, workshop_id, payment_attempt_id)
    end
  end

  defp create_external_payment_attempt(workshop, workshop_id, payment_attempt_id) do
    with {:ok, _eligible} <- external_registration_workshop_for_completion(workshop),
         :ok <- ensure_workshop_capacity(workshop_id, workshop.max_capacity),
         {:ok, amount} <- normalize_positive_integer(workshop.price_non_member) do
      attempt =
        Repo.insert!(%PaymentAttempt{
          id: payment_attempt_id,
          club_activity_id: workshop_id,
          actor_type: "external",
          amount: amount,
          currency: "eur",
          status: "pending"
        })

      {attempt, workshop}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_external_checkout_session(
         %PaymentAttempt{stripe_checkout_session_id: id},
         _workshop,
         _return_url
       )
       when is_binary(id) do
    stripe_retrieve_checkout_session(id)
  end

  defp ensure_external_checkout_session(attempt, workshop, return_url) do
    case stripe_create_checkout_session(attempt, workshop, return_url) do
      {:ok, %{"id" => id} = checkout_session} when is_binary(id) ->
        attempt
        |> Ecto.Changeset.change(stripe_checkout_session_id: id)
        |> Repo.update!()

        {:ok, checkout_session}

      _ ->
        {:error, :payment_failed}
    end
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
    with {:ok, checkout_session} <- stripe_retrieve_checkout_session(checkout_session_id),
         :ok <- validate_external_checkout_session(checkout_session, workshop_id),
         {:ok, customer} <- external_checkout_customer(checkout_session),
         {:ok, attempt} <-
           load_or_recover_external_attempt(workshop_id, checkout_session, customer.email),
         :ok <- validate_payment_attempt_amount(attempt, checkout_session),
         :ok <- maybe_set_receipt_email(checkout_session, customer.email),
         {:ok, %Registration{} = registration} <-
           Repo.transaction(fn ->
             complete_external_registration_transaction(
               workshop_id,
               attempt,
               checkout_session,
               customer
             )
           end) do
      {:ok, registration}
    else
      {:ok, {:compensation_pending, _refund}} -> {:error, :compensation_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels the current member's active Workshop registration.
  """
  def current_member_registration(workshop_id, user_id)
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
      nil -> {:error, :not_found}
      registration -> {:ok, registration}
    end
  end

  @spec cancel_member_registration(binary(), binary(), keyword()) ::
          {:ok, %{registration: Registration.t(), refund_pending: boolean()}}
          | {:error, :not_found | {:version_precondition_failed, Registration.t()}}
  def cancel_member_registration(workshop_id, user_id, opts \\ [])
      when is_binary(workshop_id) and is_binary(user_id) and is_list(opts) do
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
        case check_registration_precondition(registration, opts) do
          :ok -> cancel_existing_member_registration(registration, workshop_id, user_id, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp cancel_existing_member_registration(registration, workshop_id, user_id, opts) do
    case refund_eligibility(registration.id) do
      {:ok, _registration} ->
        refund_cancelled_member(registration, workshop_id, user_id, opts)

      {:error, _ineligible_reason} ->
        cancel_member_without_refund(registration, opts)
    end
  end

  defp refund_cancelled_member(registration, workshop_id, user_id, opts) do
    case process_refund(
           workshop_id,
           registration.id,
           "Member cancelled registration",
           user_id,
           opts
         ) do
      {:ok, refund} ->
        {:ok,
         %{
           registration: Repo.get!(Registration, registration.id),
           refund_pending: refund.status == "pending"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_member_without_refund(registration, _opts) do
    registration
    |> Ecto.Changeset.change(
      status: "cancelled",
      cancelled_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, %{registration: updated, refund_pending: false}}
      {:error, %Ecto.StaleEntryError{}} -> current_registration_error(registration.id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_registration_precondition(registration, opts) do
    case Keyword.get(opts, :expected_lock_version) do
      nil ->
        :ok

      :* ->
        :ok

      expected when is_integer(expected) and expected == registration.lock_version ->
        :ok

      expected_versions when is_list(expected_versions) ->
        if registration.lock_version in expected_versions,
          do: :ok,
          else: {:error, {:version_precondition_failed, registration}}

      _ ->
        {:error, {:version_precondition_failed, registration}}
    end
  end

  defp current_registration_error(registration_id) do
    case Repo.get(Registration, registration_id) do
      nil -> {:error, :not_found}
      current -> {:error, {:version_precondition_failed, current}}
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
        do: cancellation_refund_eligibility(workshop_id, registration_id),
        else: refund_eligibility(registration_id)

    with {:ok, %Registration{club_activity_id: ^workshop_id} = registration} <- eligibility,
         {:ok, refund} <-
           create_durable_refund_obligation(registration, reason, requested_by, opts) do
      {:ok, refund}
    else
      {:ok, %Registration{}} -> {:error, :registration_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_durable_refund_obligation(registration, reason, requested_by, opts) do
    Repo.transaction(fn ->
      registration =
        Repo.one!(from(r in Registration, where: r.id == ^registration.id, lock: "FOR UPDATE"))

      case check_registration_precondition(registration, opts) do
        {:error, reason} -> Repo.rollback(reason)
        :ok -> :ok
      end

      if Repo.exists?(from(rf in Refund, where: rf.registration_id == ^registration.id)) do
        Repo.rollback(:already_requested)
      end

      refund = create_refund_attempt!(registration, reason, requested_by)

      refund.id
      |> then(&Dhc.Workshops.Workers.RefundWorker.new(%{refund_id: &1}))
      |> Oban.insert!()

      mark_registration_refunded(registration)
      refund
    end)
    |> case do
      {:ok, refund} -> {:ok, refund}
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
        email: r.email,
        lock_version: r.lock_version
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
    # ALE-181: participant identity is read from the registration snapshot
    # (`display_name`, `email`), not a live join. Only the registration is
    # joined to reach its snapshot; `user_profiles`/`external_users` are no
    # longer touched here.
    from(rf in Refund,
      inner_join: r in Registration,
      on: r.id == rf.registration_id,
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
        display_name: r.display_name,
        email: r.email
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
      |> Ecto.Changeset.optimistic_lock(:lock_version)
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
  def update_workshop(workshop_id, attrs, opts \\ [])
      when is_binary(workshop_id) and is_map(attrs) do
    with %Workshop{} = workshop <- Repo.get(Workshop, workshop_id),
         :ok <- check_version_precondition(workshop, opts),
         :ok <- authorize_update(workshop, attrs) do
      workshop
      |> Workshop.management_changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
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
  def delete_workshop(workshop_id, opts \\ []) when is_binary(workshop_id) do
    {:ok, result} =
      Repo.transaction(fn -> delete_workshop_locked(workshop_id, opts) end)

    result
  end

  defp delete_workshop_locked(workshop_id, opts) do
    workshop = Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))

    case workshop do
      nil ->
        {:error, :not_found}

      %Workshop{archived_at: %DateTime{}} ->
        {:error, :already_archived}

      %Workshop{} = workshop ->
        case check_version_precondition(workshop, opts) do
          :ok -> delete_or_archive_workshop(workshop)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp check_version_precondition(workshop, opts) do
    case Keyword.get(opts, :expected_lock_version) do
      nil ->
        :ok

      :* ->
        :ok

      version when is_integer(version) and version == workshop.lock_version ->
        :ok

      versions when is_list(versions) ->
        if workshop.lock_version in versions,
          do: :ok,
          else: {:error, {:version_precondition_failed, workshop_summary(workshop.id)}}

      _version ->
        {:error, {:version_precondition_failed, workshop_summary(workshop.id)}}
    end
  end

  defp delete_or_archive_workshop(workshop) do
    if has_registrations?(workshop.id) do
      archive_workshop(workshop)
    else
      {:ok, _} = workshop |> Ecto.Changeset.optimistic_lock(:lock_version) |> Repo.delete()
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
      |> Ecto.Changeset.optimistic_lock(:lock_version)
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
  """
  @spec cancel_workshop(binary()) :: {:ok, Workshop.t()} | {:error, :not_found | :not_cancellable}
  def cancel_workshop(workshop_id, requested_by \\ nil) when is_binary(workshop_id) do
    Repo.transaction(fn -> cancel_workshop_locked(workshop_id, requested_by) end)
    |> case do
      {:ok, workshop} -> {:ok, workshop}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_workshop_locked(workshop_id, requested_by) do
    workshop = Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))

    case workshop do
      nil -> Repo.rollback(:not_found)
      %Workshop{status: status} when status != "published" -> Repo.rollback(:not_cancellable)
      %Workshop{} = workshop -> cancel_published_workshop(workshop, requested_by)
    end
  end

  defp cancel_published_workshop(workshop, requested_by) do
    maybe_refund_cancelled_workshop(workshop.id, requested_by)

    workshop
    |> Ecto.Changeset.change(status: "cancelled")
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update!()
  end

  defp maybe_refund_cancelled_workshop(workshop_id, requested_by) when is_binary(requested_by) do
    workshop_id
    |> active_paid_registrations()
    |> Enum.each(&create_cancellation_refund(&1, requested_by))
  end

  defp maybe_refund_cancelled_workshop(_workshop_id, _requested_by), do: :ok

  defp create_cancellation_refund(registration, requested_by) do
    unless Repo.exists?(from(rf in Refund, where: rf.registration_id == ^registration.id)) do
      refund = create_refund_attempt!(registration, "Workshop cancelled", requested_by)

      refund.id
      |> then(&Dhc.Workshops.Workers.RefundWorker.new(%{refund_id: &1}))
      |> Oban.insert!()

      mark_registration_refunded(registration)
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

  defp member_registration_workshop_for_update(workshop_id) do
    workshop =
      Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))

    case workshop do
      nil -> {:error, :not_found}
      %Workshop{archived_at: %DateTime{}} -> {:error, :not_found}
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

  defp insert_member_registration(workshop_id, user_id, payment_intent, attempt) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # ALE-181: capture the attendee snapshot at write time so reads no
    # longer join back to `user_profiles`/`principals`. A missing profile
    # resolves to the sentinel rather than failing the registration.
    {display_name, email} = member_snapshot(user_id)

    %Registration{
      club_activity_id: workshop_id,
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
    }
    |> Repo.insert!()
  end

  # ALE-181: resolve the member attendee snapshot (`display_name` from
  # `user_profiles` first/last name, `email` from `principals.email`) for a
  # `member_user_id` (which is the Principal id). Returns the
  # `@unknown_member` sentinel with a `nil` email when the profile is
  # missing so the registration insert never fails on a dangling id.
  defp member_snapshot(principal_id) do
    row =
      from(up in UserProfile,
        left_join: p in Principal,
        on: p.id == up.principal_id,
        where: up.principal_id == ^principal_id,
        select: %{first_name: up.first_name, last_name: up.last_name, email: p.email}
      )
      |> Repo.one()

    case row do
      nil ->
        {@unknown_member, nil}

      %{first_name: first, last_name: last, email: email} ->
        name = String.trim("#{first || ""} #{last || ""}")

        display_name =
          if name == "", do: @unknown_member, else: name

        {display_name, email}
    end
  end

  defp external_registration_workshop(%Workshop{} = workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      start_date: workshop.start_date,
      end_date: workshop.end_date,
      location: workshop.location,
      price_non_member: trunc(workshop.price_non_member),
      max_capacity: workshop.max_capacity
    }
  end

  defp stripe_create_checkout_session(attempt, workshop, return_url) do
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
      "line_items[0][price_data][unit_amount]": trunc(workshop.price_non_member),
      "line_items[0][price_data][product_data][name]": workshop.title,
      "metadata[type]": @workshop_registration_metadata_type,
      "metadata[actor_type]": @external_registration_actor_type,
      "metadata[workshop_id]": workshop.id,
      "metadata[payment_attempt_id]": attempt.id
    ]

    case stripe_adapter().create_checkout_session(%{
           body: body,
           idempotency_key: "workshop-payment-attempt:#{attempt.id}"
         }) do
      {:ok, %{"id" => _id} = response} -> {:ok, response}
      _ -> {:error, :payment_failed}
    end
  end

  defp stripe_retrieve_checkout_session(checkout_session_id) do
    case stripe_adapter().retrieve_checkout_session(checkout_session_id) do
      {:ok, %{"id" => _id} = response} -> {:ok, response}
      _ -> {:error, :checkout_session_not_found}
    end
  end

  defp validate_external_checkout_session(checkout_session, workshop_id) do
    metadata = Map.get(checkout_session, "metadata", %{}) || %{}

    cond do
      Map.get(checkout_session, "status") != "complete" or
          Map.get(checkout_session, "payment_status") != "paid" ->
        {:error, :payment_not_completed}

      metadata["type"] != @workshop_registration_metadata_type or
        metadata["actor_type"] != @external_registration_actor_type or
          metadata["workshop_id"] != workshop_id ->
        {:error, :payment_metadata_mismatch}

      not is_integer(Map.get(checkout_session, "amount_total")) ->
        {:error, :payment_metadata_mismatch}

      true ->
        :ok
    end
  end

  defp external_checkout_customer(checkout_session) do
    details = Map.get(checkout_session, "customer_details", %{}) || %{}

    email =
      (Map.get(details, "email") || Map.get(checkout_session, "customer_email") || "")
      |> String.trim()

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

      _ ->
        {:error, :customer_details_missing}
    end
  end

  defp load_or_recover_external_attempt(workshop_id, checkout_session, email) do
    checkout_session_id = Map.fetch!(checkout_session, "id")
    metadata = Map.get(checkout_session, "metadata", %{}) || %{}

    Repo.transaction(fn ->
      load_or_recover_external_attempt_locked(
        workshop_id,
        checkout_session_id,
        metadata,
        email
      )
    end)
    |> case do
      {:ok, attempt} -> {:ok, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_or_recover_external_attempt_locked(
         workshop_id,
         checkout_session_id,
         metadata,
         email
       ) do
    attempt = external_attempt_from_metadata!(metadata, workshop_id, checkout_session_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attempt
    |> Ecto.Changeset.change(
      external_email: email,
      stripe_checkout_session_id: checkout_session_id,
      status: paid_attempt_status(attempt.status),
      paid_at: attempt.paid_at || now
    )
    |> Repo.update!()
  end

  defp external_attempt_from_metadata!(metadata, workshop_id, checkout_session_id) do
    case payment_attempt_from_metadata(metadata) do
      %PaymentAttempt{
        club_activity_id: ^workshop_id,
        actor_type: "external",
        stripe_checkout_session_id: stored_id
      } = attempt
      when is_nil(stored_id) or stored_id == checkout_session_id ->
        attempt

      %PaymentAttempt{} ->
        Repo.rollback(:payment_metadata_mismatch)

      nil ->
        Repo.rollback(:payment_metadata_mismatch)
    end
  end

  defp paid_attempt_status("pending"), do: "paid"
  defp paid_attempt_status(status), do: status

  defp payment_attempt_from_metadata(%{"payment_attempt_id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(PaymentAttempt, id)
      :error -> nil
    end
  end

  defp payment_attempt_from_metadata(_metadata), do: nil

  defp maybe_set_receipt_email(checkout_session, email) do
    case Map.get(checkout_session, "payment_intent") do
      payment_intent_id when is_binary(payment_intent_id) ->
        _ = stripe_adapter().update_payment_intent(payment_intent_id, receipt_email: email)

        :ok

      _ ->
        :ok
    end
  end

  defp complete_external_registration_transaction(
         workshop_id,
         attempt,
         checkout_session,
         customer
       ) do
    checkout_session_id = Map.fetch!(checkout_session, "id")
    payment_intent_id = Map.get(checkout_session, "payment_intent")

    attempt =
      Repo.one!(from(pa in PaymentAttempt, where: pa.id == ^attempt.id, lock: "FOR UPDATE"))

    existing_registration =
      Repo.get_by(Registration, payment_attempt_id: attempt.id) ||
        Repo.get_by(Registration, stripe_checkout_session_id: checkout_session_id)

    existing_refund = Repo.get_by(Refund, payment_attempt_id: attempt.id)

    workshop =
      Repo.one(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))

    with %Workshop{} = workshop <- workshop,
         nil <- existing_registration,
         nil <- existing_refund,
         {:ok, _workshop} <- external_registration_workshop_for_completion(workshop),
         {:ok, external_user} <- upsert_external_user(customer),
         :ok <- ensure_no_active_external_registration(workshop_id, external_user.id),
         :ok <- ensure_workshop_capacity(workshop_id, workshop.max_capacity) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # ALE-181: capture the attendee snapshot at write time. The external
      # checkout customer details are the source of truth for the snapshot;
      # `upsert_external_user/1` already normalized them, so reuse the
      # customer map rather than re-reading the upserted `external_users` row.
      display_name =
        String.trim("#{customer.first_name || ""} #{customer.last_name || ""}")

      display_name =
        if display_name == "", do: @unknown_member, else: display_name

      registration =
        %Registration{
          club_activity_id: workshop_id,
          external_user_id: external_user.id,
          display_name: display_name,
          email: customer.email,
          status: "confirmed",
          stripe_checkout_session_id: checkout_session_id,
          payment_attempt_id: attempt.id,
          amount_paid: attempt.amount,
          currency: attempt.currency,
          confirmed_at: now,
          registered_at: now
        }
        |> Repo.insert!()

      attempt
      |> Ecto.Changeset.change(status: "registered", paid_at: now, concluded_at: now)
      |> Repo.update!()

      registration
    else
      nil ->
        refund =
          create_compensating_refund!(attempt, "Workshop unavailable", payment_intent_id)

        {:compensation_pending, refund}

      %Registration{} = registration ->
        registration

      %Refund{} = refund ->
        {:compensation_pending, refund}

      {:error, reason} when reason in [:not_found, :already_registered, :full] ->
        refund =
          create_compensating_refund!(
            attempt,
            external_compensation_reason(reason),
            payment_intent_id
          )

        {:compensation_pending, refund}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp external_compensation_reason(:already_registered), do: "Attendee already registered"
  defp external_compensation_reason(:full), do: "Workshop capacity exhausted"
  defp external_compensation_reason(:not_found), do: "Workshop unavailable"

  defp external_registration_workshop_for_completion(%Workshop{
         status: "published",
         archived_at: nil,
         is_public: true,
         price_non_member: price
       })
       when not is_nil(price) and price >= 0,
       do: {:ok, :eligible}

  defp external_registration_workshop_for_completion(_workshop), do: {:error, :not_found}

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
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      ],
      conflict_target: :email,
      returning: true
    )
  end

  defp ensure_no_active_external_registration(workshop_id, external_user_id) do
    exists? =
      Repo.exists?(
        from(r in Registration,
          where:
            r.club_activity_id == ^workshop_id and r.external_user_id == ^external_user_id and
              r.status in @counted_registration_statuses
        )
      )

    if exists?, do: {:error, :already_registered}, else: :ok
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

  defp stripe_retrieve_payment_intent(payment_intent_id) do
    case stripe_adapter().retrieve_payment_intent(payment_intent_id) do
      {:ok, %{"id" => _id} = body} -> {:ok, body}
      {:ok, _body} -> {:error, :payment_failed}
      {:error, _reason} -> {:error, :payment_failed}
    end
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

  defp cancellation_refund_eligibility(workshop_id, registration_id) do
    with {:ok, registration} <- registration_for_refund(workshop_id, registration_id) do
      if Repo.exists?(from(rf in Refund, where: rf.registration_id == ^registration_id)) do
        {:error, :already_requested}
      else
        {:ok, registration}
      end
    end
  end

  defp create_refund_attempt!(registration, reason, requested_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    id = Ecto.UUID.generate()

    Repo.insert!(%Refund{
      id: id,
      registration_id: registration.id,
      refund_amount: registration.amount_paid,
      refund_reason: reason,
      status: "pending",
      requested_at: now,
      requested_by: requested_by,
      stripe_payment_intent_id: registration.stripe_payment_intent_id,
      idempotency_key: "workshop-refund:#{id}"
    })
  end

  defp mark_registration_refunded(registration) do
    registration
    |> Ecto.Changeset.change(status: "refunded")
    |> Ecto.Changeset.optimistic_lock(:lock_version)
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

  defp stripe_adapter do
    Application.fetch_env!(:dhc, :workshop_stripe_adapter)
  end

  defp transition_workshop(workshop_id, from_status, to_status, invalid_reason) do
    case Repo.get(Workshop, workshop_id) do
      nil ->
        {:error, :not_found}

      %Workshop{status: ^from_status} = workshop ->
        workshop
        |> Ecto.Changeset.change(status: to_status)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
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
    from(w in Workshop,
      left_join: i in WorkshopInterest,
      on: i.club_activity_id == w.id,
      left_join: r in Registration,
      on: r.club_activity_id == w.id,
      where: is_nil(w.archived_at),
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
        lock_version: w.lock_version,
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
