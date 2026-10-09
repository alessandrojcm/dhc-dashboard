defmodule Dhc.Waitlist do
  @moduledoc """
  Waitlist context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.CursorPagination
  alias Dhc.Invitations.Invitation
  alias Dhc.Waitlist.Standing
  alias Dhc.Waitlist.WaitlistGuardian
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Repo

  @waitlist_open_key "waitlist_open"
  # The first name fills the Intake Email `firstName` placeholder, so it is
  # held to that placeholder's maximum (the BeginnersWorkshops EmailType
  # maxima; a test keeps the two equal).
  @first_name_max_length 40
  @restore_window_months 3
  @age_years_sql "EXTRACT(YEAR FROM AGE(CURRENT_DATE, ?))::int"
  @allowed_limits [10, 25, 50, 100]
  # The Waitlist view lists the queue (`waiting`, the default) or removed
  # people; attended, invited and joined people have left the Waitlist view.
  @listable_statuses ~w(waiting removed)
  @default_listed_status "waiting"
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
  Sets whether the public waitlist accepts registrations.
  """
  @spec set_open(boolean()) :: {:ok, %{is_open: boolean()}} | {:error, :not_found}
  def set_open(open?) when is_boolean(open?) do
    value = if open?, do: "true", else: "false"

    from(s in "settings", where: field(s, :key) == ^@waitlist_open_key)
    |> Repo.update_all(set: [value: value])
    |> case do
      {1, _rows} -> {:ok, %{is_open: open?}}
      {0, _rows} -> {:error, :not_found}
    end
  end

  @doc """
  Returns domain-shaped analytics over the `waiting` queue for the dashboard.

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
    # The four aggregates are independent scans over the same base join; run
    # them concurrently so response latency is the slowest scan, not the sum.
    # Each task checks out its own pool connection.
    [
      total_count: &total_count/0,
      average_age: &average_age/0,
      gender_distribution: &gender_distribution/0,
      age_distribution: &age_distribution/0
    ]
    |> Task.async_stream(fn {key, fun} -> {key, fun.()} end, timeout: :infinity)
    |> Map.new(fn {:ok, {key, value}} -> {key, value} end)
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
  Public Waitlist registration (spec stories 115 and 122).

  Normalizes email/pronouns, then creates the Waitlist entry (`waiting`,
  priority = now), its inactive `user_profiles` row and, for a minor, one
  Guardian row, all in one transaction.

  A `removed` email that registers again **reopens** at the back of the
  queue: its standing goes back to `waiting` through `change_standing/2`,
  its priority (`initial_registration_date`) becomes the re-registration
  date and its profile and Guardian take the new details.

  Registration is refused, changing nothing, when the email
  `:email_on_waitlist` (any standing but `removed`), `:email_is_principal`
  (a Member or former Member) or `:email_has_pending_invitation`. The public
  HTTP edge answers those refusals exactly like a new entry so it is not an
  email oracle; callers outside admin tooling must not surface them either.
  """
  @spec create_entry(map(), keyword()) ::
          {:ok, map()} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def create_entry(attrs, opts \\ []) when is_map(attrs) do
    with :ok <- ensure_open(),
         {:ok, normalized} <- normalize_create_attrs(attrs) do
      now = now(opts)
      Repo.transaction(fn -> register(normalized, now, :public) |> or_rollback() end)
    end
  end

  @doc """
  The staff-only "add a new person" path (spec stories 36 and 37).

  Validates the registration details exactly like `create_entry/2` and
  creates a `waiting` entry whose priority is the creation date. Unlike
  public registration it works while registration is closed and returns
  its refusals: `:email_on_waitlist` (any standing, `removed` included:
  restore that entry instead), `:email_is_principal` and
  `:email_has_pending_invitation`.

  Runs inside the caller's transaction when there is one (Fast-track), so
  its writes commit or roll back with the caller's; otherwise in its own.
  Every refusal is decided before the first write.

  `gender: :optional` is for the one-time spreadsheet import only
  (`Dhc.Waitlist.Import`): the sheet has no gender column, so imported
  people are stored with no gender rather than an invented one.
  Registration and staff adds keep gender required.
  """
  @spec add_person(map(), keyword()) ::
          {:ok, map()} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def add_person(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- normalize_create_attrs(attrs, Keyword.get(opts, :gender, :required)) do
      in_callers_transaction(fn -> register(normalized, now(opts), :staff) end)
    end
  end

  defp in_callers_transaction(fun) do
    if Repo.in_transaction?(),
      do: fun.(),
      else: Repo.transaction(fn -> fun.() |> or_rollback() end)
  end

  @doc """
  Restores a `removed` entry to `waiting` with its original priority (spec
  story 118), within 3 calendar months of its removal.

  Refused with `:not_found`, `:not_removed` or `:restore_window_passed`.
  Returns the entry's admin view.
  """
  @spec restore(Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :not_removed | :restore_window_passed}
  def restore(entry_id, opts \\ []) when is_binary(entry_id) do
    now = now(opts)

    Repo.transaction(fn ->
      with {:ok, entry} <- lock_entry(entry_id),
           :ok <- ensure_restorable(entry, now),
           {:ok, _entry} <- change_standing(entry.id, "waiting") do
        entry.id
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, id} -> get_entry(id)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether a person removed at `removed_at` may still be restored at `now`:
  within #{@restore_window_months} calendar months of the removal.
  """
  @spec restorable?(DateTime.t(), DateTime.t()) :: boolean()
  def restorable?(%DateTime{} = removed_at, %DateTime{} = now) do
    DateTime.compare(now, DateTime.shift(removed_at, month: @restore_window_months)) != :gt
  end

  @doc "The longest first name the Waitlist accepts: its Intake Email placeholder maximum."
  @spec first_name_max_length() :: pos_integer()
  def first_name_max_length, do: @first_name_max_length

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

  Only admin notes are editable. Waitlist Status changes only through
  `change_standing/2`, so a payload carrying `status` (or anything other than
  `adminNotes`) is refused with `{:error, :invalid_payload}`.
  """
  @spec update_entry(Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, :not_found} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def update_entry(id, attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_update_attrs(attrs) do
      update_normalized_entry(id, normalized)
    end
  end

  defp update_normalized_entry(id, normalized) do
    case Repo.get(WaitlistEntry, id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> WaitlistEntry.admin_notes_changeset(normalized)
        |> Repo.update()
        |> case do
          {:ok, _entry} -> get_entry(id)
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  The one Waitlist standing function (ALE-375, ADR 0029).

  Changes the entry's Waitlist Status to `to` when `Dhc.Waitlist.Standing`
  allows it from the current standing, and refuses every other change with
  `{:error, :illegal_standing_change}`. Entering `removed` stamps
  `removed_at` (the retention clock); leaving it clears the stamp. Every
  change refreshes `last_status_change`.

  It runs **inside the caller's transaction** so the standing change commits
  or rolls back with the caller's own writes (an Intake change, an
  Invitation), and raises `ArgumentError` outside one. It takes the Waitlist
  entry row lock (`FOR UPDATE`), the level after the Beginners' Workshop in
  the ADR 0029 lock order, and reads the current standing under it.
  """
  @spec change_standing(Ecto.UUID.t(), String.t()) ::
          {:ok, WaitlistEntry.t()}
          | {:error, :not_found | :illegal_standing_change | Ecto.Changeset.t()}
  def change_standing(entry_id, to) when is_binary(entry_id) and is_binary(to) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Dhc.Waitlist.change_standing/2 must run inside a transaction"
    end

    from(w in WaitlistEntry, where: w.id == ^entry_id, lock: "FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      %WaitlistEntry{status: from} = entry ->
        if Standing.allowed?(from, to) do
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          entry |> WaitlistEntry.standing_changeset(to, now) |> Repo.update()
        else
          {:error, :illegal_standing_change}
        end
    end
  end

  @doc """
  Hard-deletes one person from the Waitlist (ALE-396, spec stories 119 and
  120): their Guardian, their unclaimed UserProfile and the Waitlist entry.

  The Waitlist's only delete. It runs **inside the caller's transaction**
  (the Beginners' Workshop boundary's `delete_person` and `purge_retention`,
  which first settle the person's Carried Fee and anonymise their Intakes)
  and raises `ArgumentError` outside one. It takes the entry row lock and
  decides under it.

  Refused with `:not_found`, and with `:not_deletable` for standing
  `invited` or `joined`, a claimed profile (a Member's, which is never
  deleted) or an Invitation that still names the entry (Onboarding's).
  """
  @spec hard_delete(Ecto.UUID.t()) :: :ok | {:error, :not_found | :not_deletable}
  def hard_delete(entry_id) when is_binary(entry_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Dhc.Waitlist.hard_delete/1 must run inside a transaction"
    end

    with {:ok, entry} <- lock_entry(entry_id),
         {:ok, profiles} <- deletable_profiles(entry) do
      profile_ids = Enum.map(profiles, & &1.id)
      Repo.delete_all(from(g in WaitlistGuardian, where: g.profile_id in ^profile_ids))
      Repo.delete_all(from(p in UserProfile, where: p.id in ^profile_ids))
      Repo.delete_all(from(w in WaitlistEntry, where: w.id == ^entry.id))
      :ok
    end
  end

  defp deletable_profiles(%WaitlistEntry{status: status}) when status in ~w(invited joined),
    do: {:error, :not_deletable}

  defp deletable_profiles(%WaitlistEntry{id: id}) do
    profiles =
      Repo.all(from(p in UserProfile, where: p.waitlist_id == ^id, lock: "FOR UPDATE"))

    cond do
      Enum.any?(profiles, &(not is_nil(&1.principal_id))) -> {:error, :not_deletable}
      Repo.exists?(from(i in Invitation, where: i.waitlist_id == ^id)) -> {:error, :not_deletable}
      true -> {:ok, profiles}
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
        w.status == "waiting" and p.is_active == false and is_nil(p.principal_id) and
          not is_nil(p.date_of_birth)
  end

  defp parse_entry_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "position")
    direction = Map.get(params, "direction", "asc")
    status = blank_to_nil(Map.get(params, "status")) || @default_listed_status
    q = blank_to_nil(Map.get(params, "q"))

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      status not in @listable_statuses ->
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

  defp normalize_create_attrs(attrs, gender \\ :required) do
    with {:ok, date_of_birth} <- parse_date(required(attrs, "dateOfBirth")),
         :ok <- validate_minimum_age(date_of_birth),
         {:ok, social_media_consent} <- social_media_consent(attrs) do
      normalized = %{
        first_name: trim(required(attrs, "firstName")),
        last_name: trim(required(attrs, "lastName")),
        email: attrs |> required("email") |> trim() |> String.downcase(),
        phone_number: trim(required(attrs, "phoneNumber")),
        date_of_birth: date_of_birth,
        pronouns: attrs |> Map.get("pronouns", "") |> trim() |> String.downcase(),
        gender: gender(attrs, gender),
        gender_required?: gender == :required,
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

  # An optional gender that is blank is stored as none (nil), which the
  # blank-field check above lets through.
  defp gender(attrs, :required), do: required(attrs, "gender")

  defp gender(attrs, :optional) do
    case attrs |> Map.get("gender") |> trim() do
      "" -> nil
      gender -> gender
    end
  end

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

  # ── Registration ────────────────────────────────────────────────────
  #
  # Shared by public registration and the staff path. The existing entry is
  # locked by email first so a concurrent reopen and registration of the
  # same email serialize; the unique index on `waitlist.email` remains the
  # backstop for two first-time registrations racing.

  defp register(normalized, now, mode) do
    existing =
      from(w in WaitlistEntry, where: w.email == ^normalized.email, lock: "FOR UPDATE")
      |> Repo.one()

    with :ok <- ensure_registrable(existing, mode),
         :ok <- ensure_not_principal(normalized.email),
         :ok <- ensure_no_pending_invitation(normalized.email) do
      case existing do
        nil -> insert_person(normalized, now)
        %WaitlistEntry{} = removed -> reopen(removed, normalized, now)
      end
    end
  end

  # Public registration reopens a removed entry; the staff path restores
  # such an entry instead of re-registering it.
  defp ensure_registrable(nil, _mode), do: :ok
  defp ensure_registrable(%WaitlistEntry{status: "removed"}, :public), do: :ok
  defp ensure_registrable(%WaitlistEntry{}, _mode), do: {:error, :email_on_waitlist}

  defp ensure_not_principal(email) do
    if Repo.exists?(from(p in Principal, where: p.email == ^email)),
      do: {:error, :email_is_principal},
      else: :ok
  end

  defp ensure_no_pending_invitation(email) do
    if Repo.exists?(from(i in Invitation, where: i.email == ^email and i.status == "pending")),
      do: {:error, :email_has_pending_invitation},
      else: :ok
  end

  # Every changeset is validated before the first insert, so a refusal
  # inside a caller's transaction never leaves a partial person behind.
  defp insert_person(normalized, now) do
    entry_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()

    entry =
      %WaitlistEntry{id: entry_id}
      |> WaitlistEntry.create_changeset(%{email: normalized.email})
      |> Ecto.Changeset.change(initial_registration_date: now, last_status_change: now)

    profile = intake_changeset(%UserProfile{id: profile_id}, normalized, entry_id)
    guardian = guardian_changeset(normalized, profile_id)

    with :ok <- valid([entry, profile | List.wrap(guardian)]),
         {:ok, entry} <- insert_entry(entry),
         {:ok, profile} <- Repo.insert(profile),
         :ok <- maybe_insert(guardian) do
      {:ok, %{id: entry.id, profile_id: profile.id, status: entry.status}}
    end
  end

  defp reopen(%WaitlistEntry{} = entry, normalized, now) do
    profile =
      from(p in UserProfile, where: p.waitlist_id == ^entry.id, lock: "FOR UPDATE")
      |> Repo.one()

    profile_changeset =
      intake_changeset(profile || %UserProfile{id: Ecto.UUID.generate()}, normalized, entry.id)

    profile_id = Ecto.Changeset.get_field(profile_changeset, :id)
    guardian = guardian_changeset(normalized, profile_id)

    with :ok <- valid([profile_changeset | List.wrap(guardian)]),
         {:ok, waiting} <- change_standing(entry.id, "waiting"),
         {:ok, waiting} <-
           waiting |> WaitlistEntry.requeue_changeset(now) |> Repo.update(),
         {:ok, profile} <- Repo.insert_or_update(profile_changeset),
         {_count, _rows} <-
           Repo.delete_all(from(g in WaitlistGuardian, where: g.profile_id == ^profile.id)),
         :ok <- maybe_insert(guardian) do
      {:ok, %{id: waiting.id, profile_id: profile.id, status: waiting.status}}
    end
  end

  defp intake_changeset(profile, normalized, entry_id) do
    profile
    |> UserProfile.waitlist_intake_changeset(
      %{
        first_name: normalized.first_name,
        last_name: normalized.last_name,
        is_active: false,
        medical_conditions: normalized.medical_conditions,
        date_of_birth: normalized.date_of_birth,
        gender: normalized.gender,
        pronouns: normalized.pronouns,
        phone_number: normalized.phone_number,
        social_media_consent: normalized.social_media_consent,
        waitlist_id: entry_id
      },
      require_gender: normalized.gender_required?
    )
    |> Ecto.Changeset.validate_length(:first_name, max: @first_name_max_length)
  end

  defp guardian_changeset(%{guardian: guardian}, profile_id) do
    WaitlistGuardian.create_changeset(%WaitlistGuardian{}, %{
      profile_id: profile_id,
      first_name: guardian.first_name,
      last_name: guardian.last_name,
      phone_number: guardian.phone_number
    })
  end

  defp guardian_changeset(_normalized, _profile_id), do: nil

  defp valid(changesets) do
    case Enum.find(changesets, &(not &1.valid?)) do
      nil -> :ok
      changeset -> {:error, changeset}
    end
  end

  defp insert_entry(changeset) do
    case Repo.insert(changeset) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, changeset} ->
        if duplicate_email_changeset?(changeset),
          do: {:error, :email_on_waitlist},
          else: {:error, changeset}
    end
  end

  defp maybe_insert(nil), do: :ok

  defp maybe_insert(changeset) do
    case Repo.insert(changeset) do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp duplicate_email_changeset?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp or_rollback({:ok, value}), do: value
  defp or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp lock_entry(entry_id) do
    case Ecto.UUID.cast(entry_id) do
      {:ok, id} ->
        from(w in WaitlistEntry, where: w.id == ^id, lock: "FOR UPDATE")
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          entry -> {:ok, entry}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp ensure_restorable(%WaitlistEntry{status: "removed", removed_at: removed_at}, now) do
    if restorable?(removed_at, now), do: :ok, else: {:error, :restore_window_passed}
  end

  defp ensure_restorable(%WaitlistEntry{}, _now), do: {:error, :not_removed}

  defp now(opts) do
    opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
  end

  # Admin notes are the only editable field; `status` is refused rather than
  # ignored so a stale client cannot believe it changed a standing.
  defp normalize_update_attrs(%{"adminNotes" => admin_notes} = attrs)
       when map_size(attrs) == 1 and (is_binary(admin_notes) or is_nil(admin_notes)),
       do: {:ok, %{admin_notes: admin_notes}}

  defp normalize_update_attrs(_attrs), do: {:error, :invalid_payload}

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
        where: p.is_active == false and is_nil(p.principal_id)

    base_query
    |> filter_entries_status(opts.status)
    |> filter_entries_search(opts.q)
  end

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
      last_status_change: w.last_status_change,
      removed_at: w.removed_at
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
      where: p.is_active == false and is_nil(p.principal_id),
      select: %{
        id: w.id,
        # Numbered within the entry's own standing, so a waiting person's
        # position matches the default (waiting) listing.
        position:
          fragment(
            "row_number() OVER (PARTITION BY ? ORDER BY ? ASC, ? ASC)::int",
            w.status,
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
        last_status_change: w.last_status_change,
        removed_at: w.removed_at
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
