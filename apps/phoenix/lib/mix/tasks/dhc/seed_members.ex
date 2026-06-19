defmodule Mix.Tasks.Dhc.SeedMembers do
  @moduledoc """
  Seeds members into the local Supabase + Stripe test environments.

  Mirrors `scripts/seedMembers.js`:

    1. Creates auth users via the Supabase admin API
    2. Inserts waitlist, user_profiles, member_profiles, and user_roles
    3. Creates Stripe customers and writes the customer_id back to user_profiles

  ## Usage

      mix dhc.seed_members        # seed 10 members
      mix dhc.seed_members 25     # seed 25 members

  Requires `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` (read from the
  `:dhc` app config), plus a configured `STRIPE_SECRET_KEY`.
  """

  use Mix.Task

  import Ecto.Query

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.Stripe.Client, as: StripeClient

  @shortdoc "Seed members via Supabase auth + Stripe"

  @preferred_weapons ["longsword", "sword_and_buckler"]
  @genders [
    "man (cis)",
    "woman (cis)",
    "non-binary",
    "man (trans)",
    "woman (trans)",
    "other"
  ]
  @pronouns ["he/him", "she/her", "they/them"]
  @social_media_consent ["no", "yes_recognizable", "yes_unrecognizable"]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])
    count = parse_count(args)

    members = Enum.map(1..count, &generate_member/1)

    auth_users =
      members
      |> Enum.map(&create_auth_user/1)
      |> Enum.filter(& &1)

    if auth_users == [] do
      Mix.raise("No auth users were created; aborting seed.")
    end

    members = Enum.filter(members, fn m -> m.auth_user_id in Enum.map(auth_users, & &1["id"]) end)

    insert_waitlist_entries(members)
    insert_user_profiles(members)
    insert_member_profiles(members)
    insert_user_roles(members)

    customers = create_stripe_customers(members)
    update_customer_ids(members, customers)

    Mix.shell().info("Seeded #{length(members)} member(s)")
  end

  defp parse_count([]), do: 10
  defp parse_count([count | _]), do: String.to_integer(count)

  defp generate_member(_index) do
    auth_user_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    waitlist_id = Ecto.UUID.generate()

    first_name =
      Enum.random(
        ~w(Alex Bailey Casey Drew Erin Finley Harper Indigo Jordan Kerry Leslie Morgan Noel Riley Sage Taylor)
      )

    last_name =
      Enum.random(
        ~w(Murphy Kelly Byrne Ryan O'Brien Walsh Smith Doyle McCarthy Kennedy Lynch Brennan Collins)
      )

    %{
      auth_user_id: auth_user_id,
      profile_id: profile_id,
      waitlist_id: waitlist_id,
      email: "seed+#{System.unique_integer([:positive])}@example.com",
      first_name: first_name,
      last_name: last_name,
      phone_number: "+3538#{Enum.random(10..99)}#{Enum.random(100_000..999_999)}",
      date_of_birth: random_date_of_birth(),
      pronouns: Enum.random(@pronouns),
      gender: Enum.random(@genders),
      medical_conditions: if(Enum.random(1..3) == 1, do: "None", else: nil)
    }
  end

  defp random_date_of_birth do
    # Between roughly 18 and 60 years ago
    days = Enum.random((18 * 365)..(60 * 365))
    Date.add(Date.utc_today(), -days)
  end

  defp create_auth_user(member) do
    with {:ok, url} <- supabase_auth_admin_url(),
         {:ok, key} <- supabase_service_role_key() do
      payload = %{
        email: member.email,
        email_confirm: true,
        password: "password123",
        user_metadata: %{
          full_name: "#{member.first_name} #{member.last_name}"
        }
      }

      case Req.post(url,
             json: payload,
             headers: [
               {"authorization", "Bearer #{key}"},
               {"apikey", key},
               {"content-type", "application/json"}
             ]
           ) do
        {:ok, %Req.Response{status: status, body: %{"id" => _id} = user}}
        when status in 200..299 ->
          user

        {:ok, %Req.Response{status: status, body: body}} ->
          Mix.shell().error(
            "Supabase auth create failed for #{member.email}: #{status} #{inspect(body)}"
          )

          nil

        {:error, exception} ->
          Mix.shell().error(
            "Supabase auth create HTTP error for #{member.email}: #{Exception.message(exception)}"
          )

          nil
      end
    else
      {:error, reason} ->
        Mix.shell().error("Supabase config missing: #{reason}")
        nil
    end
  end

  defp insert_waitlist_entries(members) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(members, fn m ->
        [
          id: m.waitlist_id,
          email: m.email,
          status: "completed",
          initial_registration_date: now,
          last_status_change: now
        ]
      end)

    Repo.insert_all("waitlist", rows)
  end

  defp insert_user_profiles(members) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(members, fn m ->
        %{
          id: m.profile_id,
          supabase_user_id: m.auth_user_id,
          first_name: m.first_name,
          last_name: m.last_name,
          phone_number: m.phone_number,
          date_of_birth: m.date_of_birth,
          pronouns: m.pronouns,
          gender: m.gender,
          is_active: true,
          waitlist_id: m.waitlist_id,
          medical_conditions: m.medical_conditions,
          social_media_consent: Enum.random(@social_media_consent),
          created_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all("user_profiles", rows)
  end

  defp insert_member_profiles(members) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(members, fn m ->
        %{
          id: m.auth_user_id,
          user_profile_id: m.profile_id,
          next_of_kin_name: "#{Enum.random(~w(Mary John Pat))} #{m.last_name}",
          next_of_kin_phone: "+3538#{Enum.random(10..99)}#{Enum.random(100_000..999_999)}",
          preferred_weapon: Enum.take_random(@preferred_weapons, Enum.random(1..2)),
          membership_start_date: now,
          last_payment_date: now,
          insurance_form_submitted: false,
          additional_data: %{},
          created_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(MemberProfile, rows)
  end

  defp insert_user_roles(members) do
    rows =
      Enum.map(members, fn m ->
        [user_id: m.auth_user_id, role: "member"]
      end)

    Repo.insert_all("user_roles", rows)
  end

  defp create_stripe_customers(members) do
    # Match the JS script: only create Stripe customers for the first 25 members
    # to avoid rate limiting.
    members
    |> Enum.take(25)
    |> Enum.map(fn m ->
      body = %{
        "name" => "#{m.first_name} #{m.last_name}",
        "email" => m.email
      }

      case StripeClient.request(method: :post, url: "/v1/customers", body: body) do
        {:ok, %{"id" => _id} = customer} ->
          {m.profile_id, customer}

        other ->
          Mix.shell().error("Stripe customer create failed for #{m.email}: #{inspect(other)}")

          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp update_customer_ids(members, customers) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(members, fn m ->
      case Map.get(customers, m.profile_id) do
        nil ->
          :ok

        customer ->
          Repo.update_all(
            from(up in "user_profiles", where: up.id == ^m.profile_id),
            set: [customer_id: customer["id"], updated_at: now]
          )
      end
    end)
  end

  defp supabase_auth_admin_url do
    case Application.get_env(:dhc, :supabase_url) do
      nil -> {:error, :supabase_url_not_configured}
      "" -> {:error, :supabase_url_not_configured}
      url -> {:ok, URI.merge(url, "/auth/v1/admin/users") |> URI.to_string()}
    end
  end

  defp supabase_service_role_key do
    case Application.get_env(:dhc, :supabase_service_role_key) do
      nil -> {:error, :supabase_service_role_key_not_configured}
      "" -> {:error, :supabase_service_role_key_not_configured}
      key -> {:ok, key}
    end
  end
end
