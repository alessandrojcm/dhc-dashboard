defmodule Dhc.DevSeeds do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.Waitlist.WaitlistGuardian

  @preferred_weapons ~w(longsword sword_and_buckler)
  @genders ["man (cis)", "woman (cis)", "non-binary", "man (trans)", "woman (trans)", "other"]
  @pronouns ["he/him", "she/her", "they/them"]
  @social_media_consent ~w(no yes_recognizable yes_unrecognizable)

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

  @type auth_user :: %{id: String.t(), email: String.t()}

  @spec seed_members(pos_integer()) :: :ok
  def seed_members(count) do
    ensure_faker_started()

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
    |> maybe_create_stripe_customers()

    :ok
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

  defp create_member(attrs) do
    with {:ok, auth_user} <-
           create_auth_user(attrs.email, attrs.first_name, attrs.last_name, "password123"),
         {:ok, waitlist} <- insert_waitlist(attrs.email, "completed"),
         {:ok, profile} <- insert_user_profile(attrs, auth_user.id, waitlist.id, true),
         :ok <- insert_member_profile(auth_user.id, profile.id, attrs),
         :ok <- insert_user_roles(auth_user.id, ["member"]),
         :ok <- maybe_insert_guardian(profile.id, attrs.date_of_birth) do
      %{auth_user: auth_user, profile: profile, attrs: attrs}
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

    with {:ok, auth_user} <-
           create_auth_user(attrs.email, attrs.first_name, attrs.last_name, nil, roles),
         {:ok, profile} <- insert_user_profile(attrs, auth_user.id, nil, true, auth_user.id),
         :ok <- insert_member_profile(auth_user.id, profile.id, attrs),
         :ok <- insert_user_roles(auth_user.id, roles) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Skipping committee member #{attrs.email}: #{inspect(reason)}")
    end
  end

  defp create_auth_user(email, first_name, last_name, password, roles \\ []) do
    email = String.downcase(email)

    with nil <- existing_auth_user(email),
         {:ok, url} <- supabase_url(),
         {:ok, key} <- supabase_service_role_key() do
      body = %{
        email: email,
        email_confirm: true,
        user_metadata: %{
          full_name: "#{first_name} #{last_name}",
          display_name: "#{first_name} #{last_name}"
        },
        app_metadata: %{roles: roles}
      }

      body = if password, do: Map.put(body, :password, password), else: body

      case Req.post(url <> "/auth/v1/admin/users", json: body, headers: supabase_headers(key)) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, %{id: body["id"], email: body["email"] || email}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:supabase_auth, status, body}}

        {:error, reason} ->
          {:error, {:supabase_auth_request, reason}}
      end
    else
      %{id: _id, email: _email} = auth_user -> {:ok, auth_user}
      error -> error
    end
  end

  # `auth.users` is Supabase-owned (no Ecto schema), so keep this as a raw
  # query. Postgrex expects a binary UUID for the `id` column.
  defp existing_auth_user(email) do
    case Repo.query!("SELECT id::text, email FROM auth.users WHERE lower(email) = $1 LIMIT 1", [
           email
         ]) do
      %Postgrex.Result{rows: [[id, email]]} -> %{id: id, email: email}
      %Postgrex.Result{rows: []} -> nil
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
      supabase_user_id: auth_user_id,
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
    # Insert one row per role. `user_roles` has a `UNIQUE (user_id, role)`
    # constraint, so `on_conflict: :nothing` makes re-runs idempotent.
    Enum.reduce_while(roles, :ok, fn role, :ok ->
      %UserRole{user_id: user_id, role: role}
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :role])
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
           :supabase_user_id,
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

  defp create_stripe_customer(%{auth_user: auth_user, attrs: attrs}, stripe_key) do
    case Req.post("https://api.stripe.com/v1/customers",
           auth: {:bearer, stripe_key},
           form: [name: "#{attrs.first_name} #{attrs.last_name}", email: attrs.email]
         ) do
      {:ok, %Req.Response{status: status, body: %{"id" => customer_id}}}
      when status in 200..299 ->
        Repo.update_all(
          from(p in UserProfile, where: p.supabase_user_id == ^auth_user.id),
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

  defp supabase_url do
    url =
      Application.get_env(:dhc, :supabase_url) || System.get_env("SUPABASE_URL") ||
        System.get_env("PUBLIC_SUPABASE_URL")

    if url in [nil, ""],
      do: {:error, :missing_supabase_url},
      else: {:ok, String.trim_trailing(url, "/")}
  end

  defp supabase_service_role_key do
    key =
      Application.get_env(:dhc, :supabase_service_role_key) ||
        System.get_env("SUPABASE_SERVICE_ROLE_KEY") || System.get_env("SERVICE_ROLE_KEY")

    if key in [nil, ""], do: {:error, :missing_supabase_service_role_key}, else: {:ok, key}
  end

  defp supabase_headers(key),
    do: [
      {"apikey", key},
      {"authorization", "Bearer #{key}"},
      {"content-type", "application/json"}
    ]

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
