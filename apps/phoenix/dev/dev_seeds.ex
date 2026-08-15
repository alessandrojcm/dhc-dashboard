defmodule Dhc.DevSeeds do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth.{Principal, UserRole}
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.Waitlist.WaitlistGuardian
  alias Dhc.Workshops.{ExternalUser, Refund, Registration, Workshop, WorkshopInterest}

  @preferred_weapons ~w(longsword sword_and_buckler)
  @genders ["man (cis)", "woman (cis)", "non-binary", "man (trans)", "woman (trans)", "other"]
  @pronouns ["he/him", "she/her", "they/them"]
  @social_media_consent ~w(no yes_recognizable yes_unrecognizable)
  @workshop_statuses ~w(planned published finished cancelled)
  @refund_statuses ~w(pending processing completed failed cancelled)
  @attendance_statuses ~w(pending attended no_show excused)

  # Fakerer maintains a per-process sampler store, so each concurrent task
  # gets its own. `Application.ensure_all_started/1` cascades to transitive
  # deps (:makeup etc.) and is idempotent if :faker is already running.
  # Seed tasks call `Mix.Task.run("app.start")` first, so :faker is normally
  # already started by the time we get here — this is a defensive fallback.
  @spec ensure_faker_started :: :ok
  defp ensure_faker_started do
    case Application.ensure_all_started(:faker) do
      {:ok, _} -> :ok
      {:error, _} -> Faker.start()
    end
  end

  @spec seed_members(pos_integer()) :: :ok
  def seed_members(count) do
    ensure_faker_started()

    count
    |> create_members()
    |> maybe_create_stripe_customers()

    :ok
  end

  defp create_members(count) do
    1..count
    |> Task.async_stream(
      fn _ -> fake_member() |> create_member() end,
      max_concurrency: System.schedulers_online() * 2,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.reduce([], fn
      {:ok, nil}, acc ->
        acc

      {:ok, created}, acc ->
        [created | acc]

      {:exit, reason}, acc ->
        Mix.shell().error("Member task exited: #{inspect(reason)}")
        acc
    end)
  end

  @spec seed_waitlist(pos_integer()) :: :ok
  def seed_waitlist(count) do
    ensure_faker_started()

    1..count
    |> Task.async_stream(
      fn _ -> fake_waitlist_entry() |> create_waitlist_entry() end,
      max_concurrency: System.schedulers_online() * 2,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      {:ok, {:error, _}} -> :ok
      {:exit, reason} -> Mix.shell().error("Waitlist task exited: #{inspect(reason)}")
    end)

    :ok
  end

  @spec seed_committee_members(Path.t()) :: :ok
  def seed_committee_members(csv_path) do
    csv_path
    |> File.read!()
    |> parse_csv()
    |> Enum.each(&create_committee_member/1)

    :ok
  end

  @doc """
  Seeds Workshops with realistic fake data.

  Each Workshop gets:
    * a coordinator-style creator user profile (required `created_by` FK to auth.users)
    * random interest from seeded/existing members
    * a mix of pending and confirmed member registrations
    * a handful of external registrations
    * a few refunds on some registrations

  ## Usage

      mix seed.workshops
      mix seed.workshops 5

  Run via `mise run seed-workshops` so repo-root `.env` is loaded before Mix
  starts.
  """
  @spec seed_workshops(pos_integer()) :: :ok
  def seed_workshops(count) do
    ensure_faker_started()

    created_by = ensure_workshop_creator()

    1..count
    |> Task.async_stream(
      fn _ -> create_workshop(created_by) end,
      max_concurrency: System.schedulers_online() * 2,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      {:exit, reason} -> Mix.shell().error("Workshop task exited: #{inspect(reason)}")
    end)

    :ok
  end

  defp create_member(attrs) do
    with {:ok, principal} <- create_principal(attrs.email),
         {:ok, waitlist} <- insert_waitlist(attrs.email, "completed"),
         {:ok, profile} <- insert_user_profile(attrs, principal.id, waitlist.id, true),
         :ok <- insert_member_profile(principal.id, profile.id, attrs),
         :ok <- insert_user_roles(principal.id, ["member"]),
         :ok <- maybe_insert_guardian(profile.id, attrs.date_of_birth) do
      %{principal: principal, profile: profile, attrs: attrs}
    else
      {:error, reason} ->
        Mix.shell().error("Skipping member #{attrs.email}: #{inspect(reason)}")
        nil
    end
  end

  defp create_waitlist_entry(attrs) do
    with {:ok, waitlist} <- insert_waitlist(attrs.email, "waiting"),
         {:ok, profile} <- insert_user_profile(attrs, nil, waitlist.id, false),
         :ok <- maybe_insert_guardian(profile.id, attrs.date_of_birth) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Skipping waitlist entry #{attrs.email}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_committee_member(record) do
    roles = split_list(Map.fetch!(record, "roles"))
    date_of_birth = parse_dmy!(Map.fetch!(record, "dob"))

    attrs = %{
      email: Map.fetch!(record, "email"),
      first_name: Map.fetch!(record, "first_name"),
      last_name: Map.fetch!(record, "last_name"),
      phone_number: "",
      date_of_birth: date_of_birth,
      pronouns: Map.get(record, "pronouns"),
      gender: blank_to_nil(Map.get(record, "gender")),
      medical_conditions: nil,
      social_media_consent: "no",
      next_of_kin_name: Map.fetch!(record, "next_of_kin_name"),
      next_of_kin_phone: Map.fetch!(record, "next_of_kin_phone"),
      preferred_weapon: split_list(Map.fetch!(record, "preferred_weapon")),
      additional_data: %{"legacy" => Map.get(record, "additional_data", "")}
    }

    with {:ok, principal} <- create_principal(attrs.email),
         {:ok, profile} <- insert_user_profile(attrs, principal.id, nil, true, principal.id),
         :ok <- insert_member_profile(principal.id, profile.id, attrs),
         :ok <- insert_user_roles(principal.id, roles) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Skipping committee member #{attrs.email}: #{inspect(reason)}")
    end
  end

  # ── Workshop seeding helpers ─────────────────────────────────────

  # Creates a minimal Principal + user profile + member profile to satisfy the
  # `club_activities.created_by` FK. Returns the Principal id.
  defp ensure_workshop_creator do
    roles = ["workshop_coordinator"]
    email = "seed.workshops+#{System.unique_integer([:positive])}@example.com"
    first_name = "Workshop"
    last_name = "Seeder"

    case create_principal(email) do
      {:ok, %{id: id}} ->
        attrs = %{
          email: email,
          first_name: first_name,
          last_name: last_name,
          phone_number: "+353800000000",
          date_of_birth: ~D[1980-01-01],
          pronouns: "they/them",
          gender: "non-binary",
          medical_conditions: nil,
          social_media_consent: "no"
        }

        with {:ok, profile} <-
               insert_user_profile(attrs, id, nil, true, id),
             :ok <- insert_member_profile(id, profile.id, attrs),
             :ok <- insert_user_roles(id, roles) do
          id
        else
          {:error, reason} ->
            Mix.shell().error("Could not persist workshop creator profile: #{inspect(reason)}")
            fallback_creator()
        end

      {:error, _} ->
        fallback_creator()
    end
  end

  defp fallback_creator do
    case Repo.query!("SELECT id::text FROM principals ORDER BY created_at DESC LIMIT 1", []) do
      %Postgrex.Result{rows: [[id]]} -> id
      %Postgrex.Result{rows: []} -> Mix.raise("No Principal available for workshop creator")
    end
  end

  defp create_workshop(created_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    start_offset = :rand.uniform(60) - 30
    start_date = DateTime.add(now, start_offset * 24 * 60 * 60, :second)
    end_date = DateTime.add(start_date, :rand.uniform(8) * 60 * 60, :second)

    max_capacity = Enum.random([10, 15, 20, 25, 30])
    price_member = Enum.random([1000, 1500, 2000, 2500, 3000])
    price_non_member = trunc(price_member * 1.5)

    workshop_attrs = %{
      title: Faker.Lorem.sentence(3),
      description: Faker.Lorem.paragraph(2),
      location: Enum.random(["Dublin", "Cork", "Galway", "Limerick"]),
      start_date: start_date,
      end_date: end_date,
      max_capacity: max_capacity,
      price_member: price_member / 1,
      price_non_member: price_non_member / 1,
      is_public: :rand.uniform(3) != 1,
      refund_days: Enum.random([3, 7, 14]),
      status: Enum.random(@workshop_statuses),
      announce_discord: false,
      announce_email: false,
      created_by: created_by
    }

    with {:ok, workshop} <- insert_workshop(workshop_attrs),
         members <- fetch_or_seed_members(max_capacity),
         :ok <- seed_interests(workshop.id, members),
         :ok <- seed_registrations(workshop.id, members, price_member, price_non_member),
         :ok <- maybe_seed_external_registrations(workshop.id, price_non_member) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Skipping workshop #{workshop_attrs.title}: #{inspect(reason)}")
        :ok
    end
  end

  defp insert_workshop(attrs) do
    %Workshop{
      title: attrs.title,
      description: attrs.description,
      location: attrs.location,
      start_date: attrs.start_date,
      end_date: attrs.end_date,
      max_capacity: attrs.max_capacity,
      price_member: attrs.price_member,
      price_non_member: attrs.price_non_member,
      is_public: attrs.is_public,
      refund_days: attrs.refund_days,
      status: attrs.status,
      announce_discord: attrs.announce_discord,
      announce_email: attrs.announce_email,
      created_by: attrs.created_by
    }
    |> Repo.insert()
  rescue
    exception -> {:error, exception}
  end

  # Fetches existing member auth user ids from `user_profiles`. Falls back to
  # seeding new members if fewer than 5 exist, so the task is self-contained.
  defp fetch_or_seed_members(capacity) do
    limit = max(capacity, 20)

    member_ids =
      Repo.all(
        from(p in UserProfile,
          where: not is_nil(p.principal_id),
          select: p.principal_id,
          limit: ^limit
        )
      )

    if length(member_ids) < 5 do
      extra = 10 - length(member_ids)

      extra
      |> create_members()
      |> Enum.map(fn %{principal: principal} -> principal.id end)
      |> Enum.concat(member_ids)
    else
      member_ids
    end
  end

  defp seed_interests(workshop_id, member_ids) do
    interest_count = Enum.random(0..min(length(member_ids), 5))

    member_ids
    |> Enum.take(interest_count)
    |> Enum.each(fn user_id ->
      %WorkshopInterest{club_activity_id: workshop_id, user_id: user_id}
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:club_activity_id, :user_id])
    end)

    :ok
  end

  defp seed_registrations(workshop_id, member_ids, price_member, _price_non_member) do
    registration_count = Enum.random(2..min(length(member_ids), 10))

    member_ids
    |> Enum.take(registration_count)
    |> Enum.each(fn user_id ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      status = weighted_registration_status()
      confirmed_at = if status == "confirmed", do: now, else: nil
      {display_name, email} = member_snapshot(user_id)

      {:ok, registration} =
        %Registration{
          club_activity_id: workshop_id,
          member_user_id: user_id,
          display_name: display_name,
          email: email,
          amount_paid: price_member,
          currency: "eur",
          status: status,
          registered_at: now,
          confirmed_at: confirmed_at,
          attendance_status: Enum.random(@attendance_statuses)
        }
        |> Repo.insert()

      maybe_seed_refund(registration)
    end)

    :ok
  end

  defp maybe_seed_external_registrations(workshop_id, price_non_member) do
    external_count = Enum.random(0..3)

    List.duplicate(:external_registration, external_count)
    |> Enum.each(fn _ ->
      external_user = insert_external_user()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      status = weighted_registration_status()

      {:ok, registration} =
        %Registration{
          club_activity_id: workshop_id,
          external_user_id: external_user.id,
          display_name: "#{external_user.first_name} #{external_user.last_name}",
          email: external_user.email,
          amount_paid: price_non_member,
          currency: "eur",
          status: status,
          registered_at: now,
          confirmed_at: if(status == "confirmed", do: now),
          attendance_status: Enum.random(@attendance_statuses)
        }
        |> Repo.insert()

      maybe_seed_refund(registration)
    end)

    :ok
  end

  defp insert_external_user do
    {:ok, external_user} =
      %ExternalUser{
        first_name: Faker.Person.first_name(),
        last_name: Faker.Person.last_name(),
        email: Faker.Internet.email(),
        phone_number: phone_number()
      }
      |> Repo.insert()

    external_user
  end

  defp member_snapshot(principal_id) do
    row =
      from(profile in UserProfile,
        left_join: principal in Principal,
        on: principal.id == profile.principal_id,
        where: profile.principal_id == ^principal_id,
        select: %{
          first_name: profile.first_name,
          last_name: profile.last_name,
          email: principal.email
        }
      )
      |> Repo.one()

    case row do
      nil ->
        {Dhc.Workshops.unknown_member(), nil}

      %{first_name: first_name, last_name: last_name, email: email} ->
        display_name = String.trim("#{first_name || ""} #{last_name || ""}")

        display_name =
          if display_name == "", do: Dhc.Workshops.unknown_member(), else: display_name

        {display_name, email}
    end
  end

  defp maybe_seed_refund(%Registration{id: registration_id, status: status}) do
    if status in ["cancelled", "refunded"] or :rand.uniform(5) == 1 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      id = Ecto.UUID.generate()

      %Refund{
        id: id,
        registration_id: registration_id,
        refund_amount: Enum.random([500, 1000, 1500]),
        refund_reason:
          Enum.random(["No longer attending", "Schedule conflict", "Requested by member"]),
        status: Enum.random(@refund_statuses),
        idempotency_key: "workshop-refund:#{id}",
        requested_at: now
      }
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:id])
    end

    :ok
  end

  defp weighted_registration_status do
    # Bias toward active registrations so seed data feels realistic.
    Enum.random(~w(pending pending confirmed confirmed confirmed cancelled refunded))
  end

  defp create_principal(email) do
    email = String.downcase(email)

    case Dhc.Auth.get_principal_by_email(email) do
      nil -> Dhc.Auth.register_principal(%{email: email})
      principal -> {:ok, principal}
    end
  end

  # ── Schema-backed inserts ──────────────────────────────────────
  #
  # All five application tables now go through their Ecto schemas instead of
  # `Repo.insert_all/2` with raw maps + string table names. Benefits:
  #   * Ecto autodumps `:binary_id` from string UUIDs (no manual `dump_uuid`).
  #   * `timestamps/1` in the schemas fills `created_at`/`updated_at`.
  #   * Field types are validated before hitting the DB.
  #   * The `preferred_weapon[]` enum cast works via Postgres's implicit
  #     `text → preferred_weapon` cast (same path the test fixtures use).

  defp insert_waitlist(email, status) do
    %WaitlistEntry{email: String.downcase(email), status: status}
    |> Repo.insert()
  rescue
    exception -> {:error, exception}
  end

  defp insert_user_profile(attrs, auth_user_id, waitlist_id, active?, id \\ nil) do
    profile = %UserProfile{
      principal_id: auth_user_id,
      first_name: attrs.first_name,
      last_name: attrs.last_name,
      phone_number: attrs.phone_number,
      date_of_birth: attrs.date_of_birth,
      pronouns: attrs.pronouns,
      gender: attrs.gender,
      is_active: active?,
      waitlist_id: waitlist_id,
      medical_conditions: attrs.medical_conditions,
      social_media_consent: attrs.social_media_consent
    }

    profile = if id, do: %{profile | id: id}, else: profile

    # Committee members re-run seeds against existing rows (idempotent upsert
    # on the primary key). For new members `id` is nil and Ecto autogenerates
    # the `:binary_id` PK, so no conflict opts are needed.
    insert_opts = user_profile_conflict_opts(id)

    case Repo.insert(profile, insert_opts) do
      {:ok, profile} ->
        refresh_profile_search_text_if_needed(profile.id, attrs.email)
        {:ok, profile}

      {:error, _} = error ->
        error
    end
  rescue
    exception -> {:error, exception}
  end

  defp insert_member_profile(auth_user_id, profile_id, attrs) do
    %MemberProfile{
      # `MemberProfile` has `@primary_key {:id, :binary_id, autogenerate: false}`
      # — the id IS the auth user id (FK to auth.users), so set it explicitly.
      id: auth_user_id,
      user_profile_id: profile_id,
      next_of_kin_name: Map.get(attrs, :next_of_kin_name, full_name()),
      next_of_kin_phone: Map.get(attrs, :next_of_kin_phone, phone_number()),
      preferred_weapon: Map.get(attrs, :preferred_weapon, random_weapons()),
      membership_start_date: random_datetime_days_ago(730),
      last_payment_date: random_datetime_days_ago(30),
      insurance_form_submitted: :rand.uniform(2) == 1,
      additional_data: Map.get(attrs, :additional_data, %{})
    }
    |> Repo.insert(
      # Idempotent: committee re-runs upsert on the PK (auth user id).
      conflict_target: [:id],
      on_conflict:
        {:replace,
         [
           :user_profile_id,
           :next_of_kin_name,
           :next_of_kin_phone,
           :preferred_weapon,
           :insurance_form_submitted,
           :additional_data,
           :updated_at
         ]}
    )
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, exception}
  end

  defp insert_user_roles(user_id, roles) do
    # Insert one row per role. `user_roles` has a `UNIQUE (principal_id, role)`
    # constraint, so `on_conflict: :nothing` makes re-runs idempotent.
    Enum.reduce_while(roles, :ok, fn role, :ok ->
      %UserRole{principal_id: user_id, role: role}
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:principal_id, :role])
      |> case do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  rescue
    exception -> {:error, exception}
  end

  defp user_profile_conflict_opts(nil), do: []

  defp user_profile_conflict_opts(_id) do
    [
      conflict_target: [:id],
      on_conflict:
        {:replace,
         [
           :principal_id,
           :first_name,
           :last_name,
           :phone_number,
           :date_of_birth,
           :pronouns,
           :gender,
           :is_active,
           :waitlist_id,
           :medical_conditions,
           :social_media_consent,
           :updated_at
         ]}
    ]
  end

  defp maybe_insert_guardian(profile_id, date_of_birth) do
    if underage?(date_of_birth) do
      %WaitlistGuardian{
        profile_id: profile_id,
        first_name: first_name(),
        last_name: last_name(),
        phone_number: phone_number()
      }
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  rescue
    exception -> {:error, exception}
  end

  defp maybe_create_stripe_customers(created_members) do
    stripe_key =
      System.get_env("STRIPE_SECRET_KEY") || Application.get_env(:dhc, :stripe_secret_key)

    if is_nil(stripe_key) or stripe_key == "" do
      Mix.shell().info("STRIPE_SECRET_KEY not configured; skipping Stripe customer creation")
      created_members
    else
      created_members
      |> Enum.take(25)
      |> Enum.each(&create_stripe_customer(&1, stripe_key))

      created_members
    end
  end

  defp create_stripe_customer(%{principal: principal, attrs: attrs}, stripe_key) do
    case Req.post("https://api.stripe.com/v1/customers",
           auth: {:bearer, stripe_key},
           form: [name: "#{attrs.first_name} #{attrs.last_name}", email: attrs.email]
         ) do
      {:ok, %Req.Response{status: status, body: %{"id" => customer_id}}}
      when status in 200..299 ->
        Repo.update_all(
          from(p in UserProfile, where: p.principal_id == ^principal.id),
          set: [customer_id: customer_id]
        )

      other ->
        Mix.shell().error("Stripe customer creation failed for #{attrs.email}: #{inspect(other)}")
    end
  end

  # `search_text` is a `GENERATED ALWAYS AS` tsvector in the baseline Ecto
  # migration (auto-populated from first_name/last_name), so the UserProfile
  # schema doesn't declare it and inserts skip it — no refresh needed. This
  # fallback only fires for legacy Supabase DBs where the column is NOT
  # generated (the old raw-SQL seeds included email in the tsvector there).
  defp refresh_profile_search_text_if_needed(profile_id, email) do
    unless generated_search_text?() do
      Repo.query!(
        """
        UPDATE user_profiles
        SET search_text = to_tsvector('english', concat_ws(' ', first_name, last_name, $2::text))
        WHERE id = $1
        """,
        [profile_id, email]
      )
    end

    :ok
  end

  defp generated_search_text? do
    %Postgrex.Result{rows: [[is_generated]]} =
      Repo.query!(
        """
        SELECT is_generated
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'search_text'
        """,
        []
      )

    is_generated == "ALWAYS"
  end

  defp parse_csv(contents) do
    [header | rows] =
      contents
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&parse_csv_line/1)

    Enum.map(rows, fn row -> header |> Enum.zip(row) |> Map.new() end)
  end

  defp parse_csv_line(line), do: parse_csv_line(String.graphemes(line), "", [], false)
  defp parse_csv_line([], field, fields, _quoted?), do: Enum.reverse([field | fields])

  defp parse_csv_line(["\"", "\"" | rest], field, fields, true),
    do: parse_csv_line(rest, field <> "\"", fields, true)

  defp parse_csv_line(["\"" | rest], field, fields, quoted?),
    do: parse_csv_line(rest, field, fields, not quoted?)

  defp parse_csv_line(["," | rest], field, fields, false),
    do: parse_csv_line(rest, "", [field | fields], false)

  defp parse_csv_line([char | rest], field, fields, quoted?),
    do: parse_csv_line(rest, field <> char, fields, quoted?)

  defp fake_member do
    first_name = first_name()
    last_name = last_name()

    %{
      first_name: first_name,
      last_name: last_name,
      email: email(first_name, last_name),
      phone_number: phone_number(),
      date_of_birth: random_date_of_birth(),
      pronouns: Enum.random(@pronouns),
      gender: Enum.random(@genders),
      medical_conditions:
        Enum.random([nil, "No known medical conditions", "Previous knee injury"]),
      social_media_consent: Enum.random(@social_media_consent)
    }
  end

  defp fake_waitlist_entry do
    fake_member()
  end

  # Fakerer-backed fake-data generators. Faker maintains per-process sampler
  # state, so these are safe to call from concurrent tasks.
  defp first_name, do: Faker.Person.first_name()
  defp last_name, do: Faker.Person.last_name()
  defp full_name, do: "#{first_name()} #{last_name()}"

  # Fakerer ships no Irish phone locale; use EnGb and force the +353 country
  # code so seeded numbers look locally plausible.
  defp phone_number do
    Faker.Phone.EnGb.cell_number()
    |> String.replace(~r/^(\+?44|0)/, "+353")
    |> String.replace(" ", "")
  end

  defp email(first_name, last_name) do
    # Fakerer's Faker.Internet.email/0 ignores the caller's chosen name, so
    # build the local-part ourselves from the fake name and keep the domain
    # from Faker for variety.
    suffix = System.unique_integer([:positive])
    local = "#{String.downcase(first_name)}.#{String.downcase(last_name)}.#{suffix}"
    "#{local}@#{Faker.Internet.domain_name()}"
  end

  # 16–65 years old, consistent with the previous hand-rolled generator.
  defp random_date_of_birth, do: Faker.Date.date_of_birth(16..65)

  defp random_datetime_days_ago(days) do
    # Truncate to seconds: MemberProfile's `:utc_datetime` fields reject
    # microseconds. The old raw SQL didn't care (Postgres timestamptz accepts
    # them), but the schema enforces second precision.
    DateTime.utc_now()
    |> DateTime.add(-:rand.uniform(days * 86_400), :second)
    |> DateTime.truncate(:second)
  end

  defp random_weapons, do: Enum.take_random(@preferred_weapons, :rand.uniform(2))

  defp underage?(date), do: Date.compare(date, Date.utc_today() |> Date.add(-18 * 365)) == :gt

  defp parse_dmy!(value) do
    [day, month, year] =
      value |> String.trim() |> String.split("/") |> Enum.map(&String.to_integer/1)

    Date.new!(year, month, day)
  end

  defp split_list(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
