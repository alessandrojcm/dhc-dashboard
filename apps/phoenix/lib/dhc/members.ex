defmodule Dhc.Members do
  @moduledoc """
  Members context functions used by Phoenix API controllers.

  This is the context shell introduced by the Members read migration
  (issue #123). Later slices (member list, analytics) extend this module.
  """

  import Ecto.Query

  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.CursorPagination
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  require Logger

  @insurance_form_link_key "hema_insurance_form_link"
  # Mirrors `member_management_view.age` (`EXTRACT(year FROM AGE(date_of_birth))`)
  # so analytics match the prior client-side aggregates exactly.
  @age_years_sql "EXTRACT(year FROM AGE(?))::int"
  @allowed_limits [10, 25, 50, 100]
  @allowed_sort_fields ~w(firstName lastName email phoneNumber age membershipStartDate lastPaymentDate subscriptionPausedUntil isActive)
  @allowed_directions ~w(asc desc)
  @allowed_membership_statuses ~w(active inactive paused)
  @profile_update_fields ~w(firstName lastName phoneNumber dateOfBirth pronouns gender medicalConditions nextOfKinName nextOfKinPhone preferredWeapon insuranceFormSubmitted socialMediaConsent)
  @epoch_datetime ~U[1970-01-01 00:00:00Z]
  @member_sort_specs %{
    "firstName" => %{field: :first_name},
    "lastName" => %{field: :last_name},
    "email" => %{field: :email},
    "phoneNumber" => %{field: :phone_number},
    "age" => %{field: :age},
    "membershipStartDate" => %{
      field: :membership_start_date,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1,
      decode: &__MODULE__.decode_datetime_cursor/1
    },
    "lastPaymentDate" => %{
      field: :last_payment_date_sort,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1,
      decode: &__MODULE__.decode_datetime_cursor/1
    },
    "subscriptionPausedUntil" => %{
      field: :subscription_paused_until_sort,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1,
      decode: &__MODULE__.decode_datetime_cursor/1
    },
    "isActive" => %{field: :is_active}
  }

  @doc """
  Returns the member insurance form link.

  Reads the `hema_insurance_form_link` settings row and exposes it as a
  domain-shaped value, not a generic settings proxy. A missing row or an
  empty/whitespace-only value is reported as `nil` so callers can render
  "not configured" without knowing the storage shape.

  RBAC is enforced at the controller layer (any authenticated user), mirroring
  the `settings` SELECT RLS policy (`USING (true)` for authenticated).
  """
  @spec insurance_form() :: %{link: String.t() | nil}
  def insurance_form do
    %{link: insurance_form_link()}
  end

  @doc """
  Returns domain-shaped members analytics for the dashboard.

  Computed server-side over active members — `member_profiles` joined to
  `user_profiles` where `is_active = true` — replacing the five browser-side
  PostgREST aggregates over `member_management_view`. The `preferred_weapon[]`
  array is unnested and counted in SQL so the browser no longer downloads
  every active member's weapon array to count it in JavaScript.

  - `total_count` counts every active member (including those without a known
    date of birth).
  - `average_age` averages ages of active members with a known date of birth,
    coerced to `0.0` when none have one.
  - `gender_distribution` and `age_distribution` exclude members whose
    `gender`/`date_of_birth` is `nil` (no "Unknown"/null bucket).
  - `weapon_distribution` returns raw enum strings; the UI prettifies them.

  RBAC is enforced at the controller layer (broad committee roles), mirroring
  the `user_profiles` SELECT RLS policy.
  """
  @spec analytics() :: %{
          total_count: non_neg_integer(),
          average_age: number(),
          gender_distribution: [%{gender: String.t(), value: non_neg_integer()}],
          age_distribution: [%{age: non_neg_integer(), value: non_neg_integer()}],
          weapon_distribution: [%{weapon: String.t(), value: non_neg_integer()}]
        }
  def analytics do
    %{
      total_count: total_count(),
      average_age: average_age(),
      gender_distribution: gender_distribution(),
      age_distribution: age_distribution(),
      weapon_distribution: weapon_distribution()
    }
  end

  @doc """
  Returns cursor-paginated, domain-shaped members for the dashboard table.

  Replaces the browser-side PostgREST read over `member_management_view`.
  `membershipStatus` is computed server-side, reproducing the legacy view's
  CASE: `inactive` when `is_active = false`; `paused` when
  `subscription_paused_until > now()`; otherwise `active`. Distinct from the
  `is_active` flag — a paused member has `is_active: true, membership_status:
  "paused"`.

  Cursor payloads bind to the query semantics (limit, search, status filter,
  sort and direction), so stale cursors from a different table state return an
  explicit `{:error, :bad_cursor}` instead of silently serving the wrong page.
  """
  @spec list_members(map()) :: {:ok, map()} | {:error, atom()}
  def list_members(params \\ %{}) do
    with {:ok, opts} <- parse_list_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &member_cursor_context/1) do
      total_count = list_total_count(opts)
      rows = list_rows(opts, cursor)

      page =
        CursorPagination.page(
          rows,
          opts,
          cursor,
          &member_cursor_context/1,
          &member_cursor_value/2
        )

      {:ok,
       %{
         members: page.visible_rows,
         total_count: total_count,
         limit: opts.limit,
         next_cursor: page.next_cursor,
         previous_cursor: page.previous_cursor
       }}
    end
  end

  @doc """
  Returns one domain-shaped member DTO by Principal id.

  This absorbs the read side of the legacy `get_member_data` RPC while keeping
  the API DTO aligned with the member list shape.
  """
  @spec get_member(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_member(member_id) do
    case member_query(member_id) |> Repo.one() do
      nil ->
        {:error, :not_found}

      member ->
        {:ok, Map.put(member, :discord_identity, discord_identity_summary(member_id))}
    end
  end

  @doc "Returns the authenticated user's identity and Stripe customer reference."
  @spec get_current_user(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_current_user(user_id) do
    query =
      from p in UserProfile,
        left_join: u in Principal,
        on: u.id == p.principal_id,
        where: p.principal_id == ^user_id,
        select: %{
          id: p.principal_id,
          first_name: p.first_name,
          last_name: p.last_name,
          email: u.email,
          phone_number: p.phone_number,
          customer_id: p.customer_id
        }

    case Repo.one(query) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Partially updates member profile facts for one Principal id.

  `isActive` is intentionally not accepted: Stripe/webhooks own that projection.
  When name or phone changes, Stripe customer fields are echoed best-effort after
  the database write; Stripe failures are logged but do not fail the API call.
  """
  @spec update_member(String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | :invalid_payload | Ecto.Changeset.t()}
  def update_member(member_id, attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "isActive") ->
        {:error, :invalid_payload}

      Enum.any?(Map.keys(attrs), &(&1 not in @profile_update_fields)) ->
        {:error, :invalid_payload}

      map_size(attrs) == 0 ->
        {:error, :invalid_payload}

      true ->
        do_update_member(member_id, attrs)
    end
  end

  @doc """
  Returns cross-cutting enum labels used by profile and waitlist forms.
  """
  @spec options() :: %{genders: [String.t()], weapons: [String.t()]}
  def options do
    %{
      genders: enum_labels("gender"),
      weapons: enum_labels("preferred_weapon")
    }
  end

  @doc false
  def decode_datetime_cursor(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> @epoch_datetime
    end
  end

  defp do_update_member(member_id, attrs) do
    Repo.transaction(fn ->
      case load_profile_pair(member_id) do
        nil ->
          Repo.rollback(:not_found)

        profile_pair ->
          update_profile_pair(member_id, profile_pair, attrs)
      end
    end)
    |> case do
      {:ok, member} -> {:ok, member}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _e in Postgrex.Error -> {:error, :invalid_payload}
  end

  defp update_profile_pair(member_id, {user_profile, member_profile}, attrs) do
    current = %{
      first_name: user_profile.first_name,
      last_name: user_profile.last_name,
      phone_number: user_profile.phone_number,
      customer_id: user_profile.customer_id
    }

    with {:ok, _user_profile} <- update_user_profile(user_profile, attrs),
         {:ok, _member_profile} <- update_member_profile(member_profile, attrs),
         {:ok, member} <- get_member(member_id) do
      maybe_echo_customer_to_stripe(current, member, attrs)
      member
    else
      {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
      {:error, :not_found} -> Repo.rollback(:not_found)
    end
  end

  defp load_profile_pair(member_id) do
    from(m in MemberProfile,
      join: p in UserProfile,
      on: p.id == m.user_profile_id,
      where: m.id == ^member_id,
      select: {p, m}
    )
    |> Repo.one()
  end

  defp update_user_profile(user_profile, attrs) do
    attrs =
      %{}
      |> put_if_present(:first_name, attrs, "firstName")
      |> put_if_present(:last_name, attrs, "lastName")
      |> put_if_present(:phone_number, attrs, "phoneNumber")
      |> put_if_present(:date_of_birth, attrs, "dateOfBirth")
      |> put_if_present(:pronouns, attrs, "pronouns")
      |> put_if_present(:gender, attrs, "gender")
      |> put_if_present(:medical_conditions, attrs, "medicalConditions")
      |> put_if_present(:social_media_consent, attrs, "socialMediaConsent")

    user_profile
    |> UserProfile.member_profile_changeset(attrs)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp update_member_profile(member_profile, attrs) do
    attrs =
      %{}
      |> put_if_present(:next_of_kin_name, attrs, "nextOfKinName")
      |> put_if_present(:next_of_kin_phone, attrs, "nextOfKinPhone")
      |> put_if_present(:preferred_weapon, attrs, "preferredWeapon")
      |> put_if_present(:insurance_form_submitted, attrs, "insuranceFormSubmitted")

    member_profile
    |> MemberProfile.member_profile_changeset(attrs)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp put_if_present(result, atom_key, source, string_key) do
    if Map.has_key?(source, string_key) do
      Map.put(result, atom_key, Map.get(source, string_key))
    else
      result
    end
  end

  defp maybe_echo_customer_to_stripe(current, member, attrs) do
    case stripe_customer_changes(current, member, attrs) do
      {_customer_id, changes} when map_size(changes) == 0 ->
        :ok

      {customer_id, changes} ->
        echo_customer_to_stripe(customer_id, changes, member.id)
    end
  end

  defp stripe_customer_changes(%{customer_id: nil}, _member, _attrs), do: {nil, %{}}

  defp stripe_customer_changes(current, member, attrs) do
    current_name = display_name(current)
    new_name = display_name(member)

    changes =
      %{}
      |> maybe_put_customer_change(
        :name,
        new_name,
        (Map.has_key?(attrs, "firstName") or Map.has_key?(attrs, "lastName")) and
          current_name != new_name
      )
      |> maybe_put_customer_change(
        :phone,
        member.phone_number,
        Map.has_key?(attrs, "phoneNumber") and current.phone_number != member.phone_number
      )

    {current.customer_id, changes}
  end

  defp display_name(profile),
    do: "#{profile.first_name || ""} #{profile.last_name || ""}" |> String.trim()

  defp maybe_put_customer_change(changes, key, value, true), do: Map.put(changes, key, value)
  defp maybe_put_customer_change(changes, _key, _value, false), do: changes

  defp echo_customer_to_stripe(customer_id, changes, member_id) do
    case Dhc.Stripe.Client.request(
           method: :post,
           url: "/v1/customers/#{URI.encode(customer_id)}",
           body: changes
         ) do
      {:ok, _body} ->
        :ok

      {:error, reason} ->
        Logger.warning("[members] Stripe customer echo failed; leaving DB update committed",
          member_id: member_id,
          customer_id: customer_id,
          reason: inspect(reason)
        )
    end
  end

  defp enum_labels(type_name) do
    from(e in "pg_enum",
      join: t in "pg_type",
      on: field(t, :oid) == field(e, :enumtypid),
      where: field(t, :typname) == ^type_name,
      order_by: field(e, :enumsortorder),
      select: field(e, :enumlabel)
    )
    |> Repo.all()
  end

  @spec insurance_form_link() :: String.t() | nil
  defp insurance_form_link do
    from(s in "settings",
      where: field(s, :key) == ^@insurance_form_link_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> normalize_link()
  end

  defp normalize_link(nil), do: nil

  defp normalize_link(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Analytics ────────────────────────────────────────────────────────

  defp total_count do
    active_members_base()
    |> select([p, _m], count(p.id, :distinct))
    |> Repo.one()
  end

  defp average_age do
    # `avg/4` ignores NULL ages (members without a date_of_birth); coalesce
    # guards the empty set so callers get 0.0 instead of nil.
    active_members_base()
    |> select(
      [p, _m],
      type(coalesce(avg(fragment(@age_years_sql, p.date_of_birth)), 0.0), :float)
    )
    |> Repo.one()
  end

  defp gender_distribution do
    active_members_base()
    |> where([p, _m], not is_nil(p.gender))
    |> group_by([p, _m], p.gender)
    |> order_by([p, _m], asc: p.gender)
    |> select([p, _m], %{gender: p.gender, value: count(p.id)})
    |> Repo.all()
  end

  defp age_distribution do
    active_members_base()
    |> where([p, _m], not is_nil(p.date_of_birth))
    |> group_by([p, _m], fragment(@age_years_sql, p.date_of_birth))
    |> order_by([p, _m], asc: fragment(@age_years_sql, p.date_of_birth))
    |> select([p, _m], %{
      age: fragment(@age_years_sql, p.date_of_birth),
      value: count()
    })
    |> Repo.all()
  end

  defp weapon_distribution do
    # Unnest the `preferred_weapon[]` array in SQL and count per weapon so the
    # browser no longer downloads every active member's weapon array. Members
    # with an empty array contribute no rows (INNER LATERAL drops them —
    # correct, they own no weapon).
    #
    # The fragment is a `SELECT weapon FROM unnest(?) AS t(weapon)` subquery so
    # the unnested value gets a real column name Ecto can address as `w.weapon`
    # (Ecto rejects selecting the whole fragment binding `w`). `inner_lateral`
    # lets the subquery reference the correlated `m.preferred_weapon` column.
    # Raw enum strings are returned; the UI prettifies them for display.
    active_members_base()
    |> join(
      :inner_lateral,
      [p, m],
      w in fragment("SELECT weapon FROM unnest(?) AS t(weapon)", m.preferred_weapon),
      on: true
    )
    |> group_by([..., w], w.weapon)
    |> order_by([..., w], asc: w.weapon)
    |> select([..., w], %{weapon: w.weapon, value: count()})
    |> Repo.all()
  end

  defp active_members_base do
    from p in UserProfile,
      join: m in MemberProfile,
      on: m.user_profile_id == p.id,
      where: p.is_active == true
  end

  # ── Members list (cursor-paginated) ─────────────────────────────────
  #
  # Mirrors the Waitlist entries cursor pattern: a positioned subquery
  # selects the DTO fields plus per-sort helper columns, the outer query
  # applies the cursor comparator (with `id` tiebreaker) and the ORDER BY,
  # and `limit + 1` detects whether another page exists.
  #
  # The base join order is `m` (member_profiles) → `p` (user_profiles) →
  # `u` (auth.users, for email) → `wg` (waitlist_guardians, left join), so
  # the first two bindings `[m, p]` are stable for the membership-status
  # `dynamic` filter clauses.

  defp parse_list_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "lastName")
    direction = Map.get(params, "direction", "asc")
    membership_status_raw = blank_to_nil(Map.get(params, "membershipStatus"))
    q = blank_to_nil(Map.get(params, "q"))

    membership_status =
      if membership_status_raw do
        membership_status_raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
      else
        nil
      end

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      membership_status != nil and
          not Enum.all?(membership_status, &(&1 in @allowed_membership_statuses)) ->
        {:error, :invalid_membership_status}

      true ->
        {:ok,
         %{
           limit: limit,
           sort: sort,
           direction: direction,
           membership_status: membership_status,
           q: q,
           cursor: blank_to_nil(Map.get(params, "cursor"))
         }}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp member_cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "membershipStatus" => opts.membership_status,
      "q" => opts.q
    }
  end

  defp list_total_count(opts) do
    opts
    |> base_list_query()
    |> select([m, _p], count(m.id))
    |> Repo.one()
  end

  defp list_rows(opts, cursor) do
    query_direction = CursorPagination.query_direction(opts, cursor)

    opts
    |> positioned_list_query()
    |> CursorPagination.apply_cursor(cursor, opts, @member_sort_specs)
    |> CursorPagination.apply_order(list_order_field(opts.sort), query_direction)
    |> limit(^opts.limit + 1)
    |> Repo.all()
    |> CursorPagination.maybe_reverse(cursor)
  end

  defp base_list_query(opts) do
    base =
      from m in MemberProfile,
        join: p in UserProfile,
        on: p.id == m.user_profile_id,
        left_join: u in Principal,
        on: u.id == p.principal_id,
        left_join: wg in "waitlist_guardians",
        on: field(wg, :profile_id) == p.id

    base
    |> filter_membership_status(opts.membership_status)
    |> filter_list_search(opts.q)
  end

  defp filter_membership_status(query, nil), do: query
  defp filter_membership_status(query, []), do: query

  defp filter_membership_status(query, statuses) do
    expr =
      Enum.reduce(statuses, nil, fn status, acc ->
        clause = status_clause(status)

        if is_nil(acc) do
          clause
        else
          dynamic([m, p], ^acc or ^clause)
        end
      end)

    where(query, [m, p], ^expr)
  end

  defp status_clause("inactive"), do: dynamic([_m, p], p.is_active == false)

  defp status_clause("paused"),
    do:
      dynamic(
        [m, _p],
        not is_nil(m.subscription_paused_until) and
          m.subscription_paused_until > fragment("NOW()")
      )

  defp status_clause("active"),
    do:
      dynamic(
        [m, p],
        p.is_active == true and
          (is_nil(m.subscription_paused_until) or m.subscription_paused_until <= fragment("NOW()"))
      )

  defp filter_list_search(query, nil), do: query

  defp filter_list_search(query, q) do
    where(
      query,
      [_m, p, u, _wg],
      fragment("? @@ websearch_to_tsquery('english', ?)", field(p, :search_text), ^q) or
        fragment("strpos(lower(?), lower(?)) > 0", u.email, ^q)
    )
  end

  defp positioned_list_query(opts) do
    opts
    |> base_list_query()
    |> select(
      [m, p, u, wg],
      %{
        id: m.id,
        first_name: p.first_name,
        last_name: p.last_name,
        email: u.email,
        phone_number: p.phone_number,
        date_of_birth: p.date_of_birth,
        gender: p.gender,
        pronouns: p.pronouns,
        is_active: p.is_active,
        preferred_weapon: m.preferred_weapon,
        membership_start_date: m.membership_start_date,
        membership_end_date: m.membership_end_date,
        last_payment_date: m.last_payment_date,
        insurance_form_submitted: m.insurance_form_submitted,
        age: fragment(@age_years_sql, p.date_of_birth),
        social_media_consent: type(p.social_media_consent, :string),
        next_of_kin_name: m.next_of_kin_name,
        next_of_kin_phone: m.next_of_kin_phone,
        guardian_first_name: field(wg, :first_name),
        guardian_last_name: field(wg, :last_name),
        guardian_phone_number: field(wg, :phone_number),
        medical_conditions: p.medical_conditions,
        subscription_paused_until: m.subscription_paused_until,
        membership_status:
          fragment(
            "CASE WHEN ? = false THEN 'inactive' WHEN ? IS NOT NULL AND ? > NOW() THEN 'paused' ELSE 'active' END",
            p.is_active,
            m.subscription_paused_until,
            m.subscription_paused_until
          ),
        # Coalesced sort helpers for nullable date sort fields, so cursor
        # comparators have a deterministic non-null value to compare against.
        last_payment_date_sort: fragment("coalesce(?, ?)", m.last_payment_date, ^@epoch_datetime),
        subscription_paused_until_sort:
          fragment("coalesce(?, ?)", m.subscription_paused_until, ^@epoch_datetime)
      }
    )
    |> subquery()
  end

  defp member_query(member_id) do
    %{sort: "lastName", q: nil, membership_status: nil}
    |> positioned_list_query()
    |> where([m], m.id == ^member_id)
  end

  defp discord_identity_summary(member_id) do
    metadata =
      ExternalIdentity
      |> where(
        [identity],
        identity.principal_id == ^member_id and identity.provider == "discord" and
          is_nil(identity.retired_at)
      )
      |> select([identity], identity.metadata)
      |> Repo.one()

    if metadata do
      %{
        username: first_metadata_value(metadata, ["preferred_username", "username"]),
        avatar_url: metadata |> first_metadata_value(["picture"]) |> safe_avatar_url()
      }
    end
  end

  defp first_metadata_value(metadata, keys) do
    Enum.find_value(keys, &normalized_metadata_value(metadata, &1))
  end

  defp normalized_metadata_value(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> value |> String.trim() |> empty_to_nil()
      _other -> nil
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp safe_avatar_url(nil), do: nil

  defp safe_avatar_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> url
      _uri -> nil
    end
  end

  defp list_order_field("firstName"), do: :first_name
  defp list_order_field("lastName"), do: :last_name
  defp list_order_field("email"), do: :email
  defp list_order_field("phoneNumber"), do: :phone_number
  defp list_order_field("age"), do: :age
  defp list_order_field("membershipStartDate"), do: :membership_start_date
  defp list_order_field("lastPaymentDate"), do: :last_payment_date_sort
  defp list_order_field("subscriptionPausedUntil"), do: :subscription_paused_until_sort
  defp list_order_field("isActive"), do: :is_active

  defp member_cursor_value(row, opts) do
    spec = Map.fetch!(@member_sort_specs, opts.sort)
    value = Map.fetch!(row, spec.field)

    if encode = Map.get(spec, :encode), do: encode.(value), else: value
  end
end
