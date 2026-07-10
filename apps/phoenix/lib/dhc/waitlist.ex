defmodule Dhc.Waitlist do
  @moduledoc """
  Waitlist context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Waitlist.WaitlistGuardian
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Repo

  @waitlist_open_key "waitlist_open"
  @age_years_sql "EXTRACT(YEAR FROM AGE(CURRENT_DATE, ?))::int"
  @allowed_limits [10, 25, 50, 100]
  @allowed_statuses ~w(waiting invited paid deferred cancelled completed no_reply joined)
  @social_media_consent_values ~w(no yes_recognizable yes_unrecognizable)
  @allowed_sort_fields ~w(position fullName status age initialRegistrationDate lastContacted lastStatusChange)
  @allowed_directions ~w(asc desc)
  @entry_sort_specs %{
    "position" => %{field: :position},
    "fullName" => %{field: :full_name_sort},
    "status" => %{field: :status},
    "age" => %{field: :age},
    "initialRegistrationDate" => %{
      field: :initial_registration_date,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1
    },
    "lastContacted" => %{
      field: :last_contacted_sort,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1
    },
    "lastStatusChange" => %{
      field: :last_status_change,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1
    }
  }

  @doc """
  Returns the public waitlist status.

  Missing or malformed settings are treated as closed so the public endpoint
  always returns a safe domain-shaped status instead of exposing settings rows.
  """
  @spec status() :: %{is_open: boolean()}
  def status do
    %{is_open: open?()}
  end

  @doc """
  Returns domain-shaped waitlist analytics for the dashboard.

  The queries intentionally read the `waitlist` and `user_profiles` storage
  tables directly inside Phoenix, rather than exposing `waitlist_management_view`
  or `user_profiles` as API resources.
  """
  @spec analytics() :: %{
          total_count: non_neg_integer(),
          average_age: number(),
          gender_distribution: [%{gender: String.t(), value: non_neg_integer()}],
          age_distribution: [%{age: non_neg_integer(), value: non_neg_integer()}]
        }
  def analytics do
    %{
      total_count: total_count(),
      average_age: average_age(),
      gender_distribution: gender_distribution(),
      age_distribution: age_distribution()
    }
  end

  @doc """
  Returns cursor-paginated, domain-shaped waitlist entries for the dashboard.

  Cursor payloads bind to the query semantics (limit, search, status, sort and
  direction), so stale cursors from a different table state return an explicit
  `{:error, :bad_cursor}` instead of silently serving the wrong page.
  """
  @spec entries(map()) :: {:ok, map()} | {:error, atom()}
  def entries(params \\ %{}) do
    with {:ok, opts} <- parse_entry_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &entry_cursor_context/1) do
      total_count = entries_total_count(opts)
      rows = entries_rows(opts, cursor)

      page =
        CursorPagination.page(rows, opts, cursor, &entry_cursor_context/1, &entry_cursor_value/2)

      {:ok,
       %{
         entries: page.visible_rows,
         total_count: total_count,
         limit: opts.limit,
         next_cursor: page.next_cursor,
         previous_cursor: page.previous_cursor
       }}
    end
  end

  @doc """
  Creates a public waitlist entry and its inactive profile atomically.

  This absorbs the legacy `insert_waitlist_entry` stored procedure behavior into
  Phoenix: normalize email/pronouns, insert the waitlist row with initial status
  `waiting`, insert the inactive `user_profiles` row, and attach one guardian
  row for minors.
  """
  @spec create_entry(map()) :: {:ok, map()} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def create_entry(attrs) when is_map(attrs) do
    with :ok <- ensure_open(),
         {:ok, normalized} <- normalize_create_attrs(attrs) do
      entry_changeset =
        WaitlistEntry.create_changeset(%WaitlistEntry{}, %{
          email: normalized.email,
          status: "waiting"
        })

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:waitlist_entry, entry_changeset)
      |> Ecto.Multi.insert(:user_profile, fn %{waitlist_entry: entry} ->
        UserProfile.waitlist_intake_changeset(%UserProfile{}, %{
          first_name: normalized.first_name,
          last_name: normalized.last_name,
          is_active: false,
          medical_conditions: normalized.medical_conditions,
          date_of_birth: normalized.date_of_birth,
          gender: normalized.gender,
          pronouns: normalized.pronouns,
          phone_number: normalized.phone_number,
          social_media_consent: normalized.social_media_consent,
          waitlist_id: entry.id
        })
      end)
      |> maybe_insert_guardian(normalized)
      |> Repo.transaction()
      |> case do
        {:ok, %{waitlist_entry: entry, user_profile: profile}} ->
          {:ok, %{id: entry.id, profile_id: profile.id, status: entry.status}}

        {:error, :waitlist_entry, changeset, _changes} ->
          if duplicate_email_changeset?(changeset),
            do: {:error, :duplicate_email},
            else: {:error, changeset}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Returns one domain-shaped waitlist entry for admin inspection.
  """
  @spec get_entry(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_entry(id) do
    case entry_by_id_query(id) |> Repo.one() do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Updates admin-owned waitlist entry fields.

  Status changes refresh `last_status_change`; admin note edits preserve the
  existing status timestamp.
  """
  @spec update_entry(Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, :not_found} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def update_entry(id, attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_update_attrs(attrs) do
      case Repo.get(WaitlistEntry, id) do
        nil ->
          {:error, :not_found}

        entry ->
          entry
          |> WaitlistEntry.admin_update_changeset(normalized)
          |> Repo.update()
          |> case do
            {:ok, _entry} -> get_entry(id)
            {:error, changeset} -> {:error, changeset}
          end
      end
    end
  end

  @doc """
  Returns guardian details for a waitlist entry, when present.
  """
  @spec get_guardian(Ecto.UUID.t()) :: {:ok, map() | nil} | {:error, :not_found}
  def get_guardian(entry_id) do
    query =
      from p in UserProfile,
        left_join: wg in WaitlistGuardian,
        on: wg.profile_id == p.id,
        where: p.waitlist_id == ^entry_id,
        select: %{
          first_name: wg.first_name,
          last_name: wg.last_name,
          phone_number: wg.phone_number
        }

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %{first_name: nil, last_name: nil, phone_number: nil} -> {:ok, nil}
      guardian -> {:ok, guardian}
    end
  end

  @spec open?() :: boolean()
  def open? do
    from(s in "settings",
      where: field(s, :key) == ^@waitlist_open_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> case do
      "true" -> true
      _ -> false
    end
  end

  defp total_count do
    base_analytics_query()
    |> select([w, _p], count(w.id, :distinct))
    |> Repo.one()
  end

  defp average_age do
    base_analytics_query()
    |> select(
      [_w, p],
      type(coalesce(avg(fragment(@age_years_sql, p.date_of_birth)), 0.0), :float)
    )
    |> Repo.one()
  end

  defp gender_distribution do
    base_analytics_query()
    |> where([_w, p], not is_nil(p.gender))
    |> group_by([_w, p], p.gender)
    |> order_by([_w, p], asc: p.gender)
    |> select([_w, p], %{gender: p.gender, value: count(p.id)})
    |> Repo.all()
  end

  defp age_distribution do
    base_analytics_query()
    |> group_by(
      [_w, p],
      fragment(@age_years_sql, p.date_of_birth)
    )
    |> order_by(
      [_w, p],
      asc: fragment(@age_years_sql, p.date_of_birth)
    )
    |> select([_w, p], %{
      age: fragment(@age_years_sql, p.date_of_birth),
      value: count()
    })
    |> Repo.all()
  end

  defp base_analytics_query do
    from w in WaitlistEntry,
      join: p in UserProfile,
      on: p.waitlist_id == w.id,
      where:
        w.status != "joined" and p.is_active == false and is_nil(p.supabase_user_id) and
          not is_nil(p.date_of_birth)
  end

  defp parse_entry_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "position")
    direction = Map.get(params, "direction", "asc")
    status = blank_to_nil(Map.get(params, "status"))
    q = blank_to_nil(Map.get(params, "q"))

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      not is_nil(status) and status not in @allowed_statuses ->
        {:error, :invalid_status}

      true ->
        {:ok,
         %{
           limit: limit,
           sort: sort,
           direction: direction,
           status: status,
           q: q,
           cursor: blank_to_nil(Map.get(params, "cursor"))
         }}
    end
  end

  defp ensure_open do
    if open?(), do: :ok, else: {:error, :waitlist_closed}
  end

  defp normalize_create_attrs(attrs) do
    with {:ok, date_of_birth} <- parse_date(required(attrs, "dateOfBirth")),
         :ok <- validate_minimum_age(date_of_birth),
         {:ok, social_media_consent} <- social_media_consent(attrs) do
      normalized = %{
        first_name: trim(required(attrs, "firstName")),
        last_name: trim(required(attrs, "lastName")),
        email: attrs |> required("email") |> trim() |> String.downcase(),
        phone_number: trim(required(attrs, "phoneNumber")),
        date_of_birth: date_of_birth,
        pronouns: attrs |> required("pronouns") |> trim() |> String.downcase(),
        gender: required(attrs, "gender"),
        medical_conditions: Map.get(attrs, "medicalConditions", ""),
        social_media_consent: social_media_consent
      }

      cond do
        Enum.any?(
          [
            normalized.first_name,
            normalized.last_name,
            normalized.email,
            normalized.phone_number,
            normalized.pronouns,
            normalized.gender
          ],
          &(&1 == "")
        ) ->
          {:error, :invalid_payload}

        minor?(date_of_birth) ->
          normalize_guardian_attrs(normalized, attrs)

        true ->
          {:ok, normalized}
      end
    end
  end

  defp required(attrs, key), do: Map.get(attrs, key, "")

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_payload}

  defp validate_minimum_age(date_of_birth) do
    if age(date_of_birth) >= 16, do: :ok, else: {:error, :invalid_payload}
  end

  defp social_media_consent(attrs) do
    value = Map.get(attrs, "socialMediaConsent", "no")

    if value in @social_media_consent_values,
      do: {:ok, value},
      else: {:error, :invalid_payload}
  end

  defp normalize_guardian_attrs(normalized, attrs) do
    guardian = %{
      first_name: trim(Map.get(attrs, "guardianFirstName")),
      last_name: trim(Map.get(attrs, "guardianLastName")),
      phone_number: trim(Map.get(attrs, "guardianPhoneNumber"))
    }

    if Enum.any?(Map.values(guardian), &(&1 == "")) do
      {:error, :invalid_payload}
    else
      {:ok, Map.put(normalized, :guardian, guardian)}
    end
  end

  defp age(date_of_birth) do
    today = Date.utc_today()
    years = today.year - date_of_birth.year
    birthday_this_year = %{date_of_birth | year: today.year}

    if Date.compare(birthday_this_year, today) == :gt do
      years - 1
    else
      years
    end
  end

  defp minor?(date_of_birth), do: age(date_of_birth) < 18

  defp maybe_insert_guardian(multi, %{guardian: guardian}) do
    Ecto.Multi.insert(multi, :waitlist_guardian, fn %{user_profile: profile} ->
      WaitlistGuardian.create_changeset(%WaitlistGuardian{}, %{
        profile_id: profile.id,
        first_name: guardian.first_name,
        last_name: guardian.last_name,
        phone_number: guardian.phone_number
      })
    end)
  end

  defp maybe_insert_guardian(multi, _normalized), do: multi

  defp duplicate_email_changeset?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp normalize_update_attrs(attrs) do
    status = blank_to_nil(Map.get(attrs, "status"))
    admin_notes = Map.get(attrs, "adminNotes", :missing)

    cond do
      is_nil(status) and admin_notes == :missing ->
        {:error, :invalid_payload}

      not is_nil(status) and status not in @allowed_statuses ->
        {:error, :invalid_status}

      admin_notes != :missing and not (is_binary(admin_notes) or is_nil(admin_notes)) ->
        {:error, :invalid_payload}

      true ->
        normalized = %{}
        normalized = if is_nil(status), do: normalized, else: Map.put(normalized, :status, status)

        normalized =
          if admin_notes == :missing,
            do: normalized,
            else: Map.put(normalized, :admin_notes, admin_notes)

        normalized =
          if is_nil(status),
            do: normalized,
            else:
              Map.put(
                normalized,
                :last_status_change,
                DateTime.utc_now() |> DateTime.truncate(:second)
              )

        {:ok, normalized}
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

  defp entry_cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "status" => opts.status,
      "q" => opts.q
    }
  end

  defp entries_total_count(opts) do
    opts
    |> base_entries_query()
    |> select([w, _p, _wg], count(w.id))
    |> Repo.one()
  end

  defp entries_rows(opts, cursor) do
    query_direction = CursorPagination.query_direction(opts, cursor)

    opts
    |> positioned_entries_query()
    |> CursorPagination.apply_cursor(cursor, opts, @entry_sort_specs)
    |> CursorPagination.apply_order(entry_order_field(opts.sort), query_direction)
    |> limit(^opts.limit + 1)
    |> Repo.all()
    |> CursorPagination.maybe_reverse(cursor)
  end

  defp base_entries_query(opts) do
    base_query =
      from w in WaitlistEntry,
        join: p in UserProfile,
        on: p.waitlist_id == w.id,
        left_join: wg in "waitlist_guardians",
        on: field(wg, :profile_id) == p.id,
        where: p.is_active == false and is_nil(p.supabase_user_id)

    base_query
    |> filter_entries_status(opts.status)
    |> filter_entries_search(opts.q)
  end

  defp filter_entries_status(query, nil), do: where(query, [w, _p, _wg], w.status != "joined")
  defp filter_entries_status(query, status), do: where(query, [w, _p, _wg], w.status == ^status)

  defp filter_entries_search(query, nil), do: query

  defp filter_entries_search(query, q) do
    where(
      query,
      [_w, p, _wg],
      fragment("? @@ websearch_to_tsquery('english', ?)", field(p, :search_text), ^q)
    )
  end

  defp positioned_entries_query(opts) do
    opts
    |> base_entries_query()
    |> select([w, p, wg], %{
      id: w.id,
      position:
        fragment(
          "row_number() OVER (ORDER BY ? ASC, ? ASC)::int",
          w.initial_registration_date,
          w.id
        ),
      full_name: fragment("concat(?, ' ', ?)", p.first_name, p.last_name),
      full_name_sort: fragment("lower(concat(?, ' ', ?))", p.first_name, p.last_name),
      email: w.email,
      phone_number: p.phone_number,
      status: type(w.status, :string),
      age: fragment(@age_years_sql, p.date_of_birth),
      initial_registration_date: w.initial_registration_date,
      last_contacted: w.last_contacted,
      last_contacted_sort:
        fragment("coalesce(?, '1970-01-01 00:00:00Z'::timestamptz)", w.last_contacted),
      medical_conditions: p.medical_conditions,
      admin_notes: w.admin_notes,
      social_media_consent: type(p.social_media_consent, :string),
      guardian_first_name: field(wg, :first_name),
      guardian_last_name: field(wg, :last_name),
      guardian_phone_number: field(wg, :phone_number),
      insurance_form_submitted: fragment("false"),
      last_status_change: w.last_status_change
    })
    |> subquery()
  end

  defp entry_by_id_query(id) do
    from entry in all_positioned_entries_query(), where: entry.id == ^id
  end

  defp all_positioned_entries_query do
    from(w in WaitlistEntry,
      join: p in UserProfile,
      on: p.waitlist_id == w.id,
      left_join: wg in WaitlistGuardian,
      on: wg.profile_id == p.id,
      where: p.is_active == false and is_nil(p.supabase_user_id),
      select: %{
        id: w.id,
        position:
          fragment(
            "row_number() OVER (ORDER BY ? ASC, ? ASC)::int",
            w.initial_registration_date,
            w.id
          ),
        full_name: fragment("concat(?, ' ', ?)", p.first_name, p.last_name),
        email: w.email,
        phone_number: p.phone_number,
        status: type(w.status, :string),
        age: fragment(@age_years_sql, p.date_of_birth),
        initial_registration_date: w.initial_registration_date,
        last_contacted: w.last_contacted,
        medical_conditions: p.medical_conditions,
        admin_notes: w.admin_notes,
        social_media_consent: type(p.social_media_consent, :string),
        guardian_first_name: wg.first_name,
        guardian_last_name: wg.last_name,
        guardian_phone_number: wg.phone_number,
        insurance_form_submitted: fragment("false"),
        last_status_change: w.last_status_change
      }
    )
    |> subquery()
  end

  defp entry_order_field("position"), do: :position
  defp entry_order_field("fullName"), do: :full_name_sort
  defp entry_order_field("status"), do: :status
  defp entry_order_field("age"), do: :age
  defp entry_order_field("initialRegistrationDate"), do: :initial_registration_date
  defp entry_order_field("lastContacted"), do: :last_contacted_sort
  defp entry_order_field("lastStatusChange"), do: :last_status_change

  defp entry_cursor_value(row, %{sort: "fullName"}), do: String.downcase(row.full_name)

  defp entry_cursor_value(row, opts) do
    spec = Map.fetch!(@entry_sort_specs, opts.sort)
    value = Map.fetch!(row, spec.field)

    if encode = Map.get(spec, :encode), do: encode.(value), else: value
  end
end
