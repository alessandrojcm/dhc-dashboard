defmodule Dhc.DevSeeds do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Repo

  @preferred_weapons ~w(longsword sword_and_buckler)
  @genders ["man (cis)", "woman (cis)", "non-binary", "man (trans)", "woman (trans)", "other"]
  @pronouns ["he/him", "she/her", "they/them"]
  @social_media_consent ~w(no yes_recognizable yes_unrecognizable)
  @first_names ~w(Aoife Cian Niamh Oisin Saoirse Fionn Roisin Eoin Caoimhe Sean Orla Liam)
  @last_names ~w(Byrne Kelly Murphy Walsh OBrien Ryan Doyle McCarthy Gallagher Kennedy Murray Nolan)

  @type auth_user :: %{id: String.t(), email: String.t()}

  @spec seed_members(pos_integer()) :: :ok
  def seed_members(count) do
    rows = Enum.map(1..count, fn _ -> fake_member() end)

    rows
    |> Enum.map(&create_member/1)
    |> Enum.reject(&is_nil/1)
    |> maybe_create_stripe_customers()

    :ok
  end

  @spec seed_waitlist(pos_integer()) :: :ok
  def seed_waitlist(count) do
    1..count
    |> Enum.map(fn _ -> fake_waitlist_entry() end)
    |> Enum.each(&create_waitlist_entry/1)

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
         {:ok, waitlist_id} <- insert_waitlist(attrs.email, "completed"),
         {:ok, profile} <- insert_user_profile(attrs, auth_user.id, waitlist_id, true),
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
    with {:ok, waitlist_id} <- insert_waitlist(attrs.email, "waiting"),
         {:ok, profile} <- insert_user_profile(attrs, nil, waitlist_id, false),
         :ok <- maybe_insert_guardian(profile.id, attrs.date_of_birth) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Skipping waitlist entry #{attrs.email}: #{inspect(reason)}")
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

  defp existing_auth_user(email) do
    case Repo.query!("SELECT id::text, email FROM auth.users WHERE lower(email) = $1 LIMIT 1", [
           email
         ]) do
      %Postgrex.Result{rows: [[id, email]]} -> %{id: id, email: email}
      %Postgrex.Result{rows: []} -> nil
    end
  end

  defp insert_waitlist(email, status) do
    case Repo.insert_all("waitlist", [%{email: String.downcase(email), status: status}],
           returning: [:id]
         ) do
      {1, [%{id: id}]} -> {:ok, id}
      result -> {:error, {:insert_waitlist, result}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp insert_user_profile(attrs, auth_user_id, waitlist_id, active?, id \\ nil) do
    auth_user_id = dump_uuid(auth_user_id)
    id = dump_uuid(id)

    row = %{
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
      social_media_consent: attrs.social_media_consent,
      created_at: now(),
      updated_at: now()
    }

    row = if id, do: Map.put(row, :id, id), else: row

    insert_opts = [returning: [:id, :date_of_birth]] ++ user_profile_conflict_opts(id)

    case Repo.insert_all("user_profiles", [row], insert_opts) do
      {1, [profile]} ->
        refresh_profile_search_text(profile.id, attrs.email)
        {:ok, profile}

      result ->
        {:error, {:insert_user_profile, result}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp insert_member_profile(auth_user_id, profile_id, attrs) do
    auth_user_id = dump_uuid(auth_user_id)

    Repo.query!(
      """
      INSERT INTO member_profiles (
        id,
        user_profile_id,
        next_of_kin_name,
        next_of_kin_phone,
        preferred_weapon,
        membership_start_date,
        last_payment_date,
        insurance_form_submitted,
        additional_data,
        created_at,
        updated_at
      )
      VALUES ($1, $2, $3, $4, $5::preferred_weapon[], $6, $7, $8, $9::jsonb, $10, $11)
      ON CONFLICT (id) DO UPDATE SET
        user_profile_id = EXCLUDED.user_profile_id,
        next_of_kin_name = EXCLUDED.next_of_kin_name,
        next_of_kin_phone = EXCLUDED.next_of_kin_phone,
        preferred_weapon = EXCLUDED.preferred_weapon,
        insurance_form_submitted = EXCLUDED.insurance_form_submitted,
        additional_data = EXCLUDED.additional_data,
        updated_at = EXCLUDED.updated_at
      """,
      [
        auth_user_id,
        profile_id,
        Map.get(attrs, :next_of_kin_name, full_name()),
        Map.get(attrs, :next_of_kin_phone, phone_number()),
        Map.get(attrs, :preferred_weapon, random_weapons()),
        random_datetime_days_ago(730),
        random_datetime_days_ago(30),
        :rand.uniform(2) == 1,
        Jason.encode!(Map.get(attrs, :additional_data, %{})),
        now(),
        now()
      ]
    )

    :ok
  rescue
    exception -> {:error, exception}
  end

  defp insert_user_roles(user_id, roles) do
    user_id = dump_uuid(user_id)
    rows = Enum.map(roles, &%{user_id: user_id, role: &1})
    Repo.insert_all("user_roles", rows, on_conflict: :nothing)
    :ok
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
      Repo.insert_all("waitlist_guardians", [
        %{
          profile_id: profile_id,
          first_name: first_name(),
          last_name: last_name(),
          phone_number: phone_number(),
          created_at: now()
        }
      ])
    end

    :ok
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
          from(p in "user_profiles",
            where: field(p, :supabase_user_id) == ^dump_uuid(auth_user.id)
          ),
          set: [customer_id: customer_id]
        )

      other ->
        Mix.shell().error("Stripe customer creation failed for #{attrs.email}: #{inspect(other)}")
    end
  end

  defp refresh_profile_search_text(profile_id, email) do
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

  defp first_name, do: Enum.random(@first_names)
  defp last_name, do: Enum.random(@last_names)
  defp full_name, do: "#{first_name()} #{last_name()}"
  defp phone_number, do: "+353#{:rand.uniform(899_999_999) + 100_000_000}"

  defp dump_uuid(nil), do: nil
  defp dump_uuid(<<_::128>> = uuid), do: uuid
  defp dump_uuid(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)

  defp email(first_name, last_name) do
    suffix = System.unique_integer([:positive])
    "#{String.downcase(first_name)}.#{String.downcase(last_name)}.#{suffix}@example.test"
  end

  defp random_date_of_birth do
    days_ago = :rand.uniform((65 - 16) * 365) + 16 * 365
    Date.utc_today() |> Date.add(-days_ago)
  end

  defp random_datetime_days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-:rand.uniform(days * 86_400), :second)
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
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
