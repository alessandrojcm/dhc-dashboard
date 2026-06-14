defmodule Dhc.MemberFixtures do
  @moduledoc """
  Test helpers for creating the minimal auth/user/member rows needed by
  Stripe-sync integration tests.
  """

  alias Dhc.Repo

  @doc """
  Inserts an auth user, a user profile, and a member profile.

  Returns a map with `auth_user_id`, `profile_id`, and `customer_id`.

  ## Options

    * `:customer_id` - override the Stripe customer id (default: auto-generated)
    * `:last_payment_date` - set the member profile's last payment date
    * `:is_active` - set the user profile's active flag
  """
  def member_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    auth_user_id_str = Ecto.UUID.generate()
    profile_id_str = Ecto.UUID.generate()

    # Postgrex expects binary UUIDs when inserting into string-named tables.
    auth_user_id = Ecto.UUID.dump!(auth_user_id_str)
    profile_id = Ecto.UUID.dump!(profile_id_str)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    customer_id = Map.get(attrs, :customer_id, "cus_#{System.unique_integer([:positive])}")

    Repo.insert_all(
      "users",
      [
        [
          id: auth_user_id,
          aud: "authenticated",
          role: "authenticated",
          email: unique_email()
        ]
      ],
      prefix: "auth"
    )

    profile_attrs =
      %{
        id: profile_id,
        supabase_user_id: auth_user_id,
        first_name: "Test",
        last_name: "Member",
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01],
        gender: "man (cis)",
        pronouns: "he/him",
        is_active: Map.get(attrs, :is_active, true),
        customer_id: customer_id,
        social_media_consent: "no",
        created_at: now,
        updated_at: now
      }

    Repo.insert_all("user_profiles", [profile_attrs])

    member_attrs =
      %{
        id: auth_user_id,
        user_profile_id: profile_id,
        next_of_kin_name: "Next of Kin",
        next_of_kin_phone: "+353820000000",
        preferred_weapon: ["longsword"],
        membership_start_date: now,
        last_payment_date: Map.get(attrs, :last_payment_date),
        insurance_form_submitted: false,
        additional_data: %{},
        created_at: now,
        updated_at: now
      }

    Repo.insert_all("member_profiles", [member_attrs])

    %{
      auth_user_id: auth_user_id_str,
      profile_id: profile_id_str,
      customer_id: customer_id
    }
  end

  defp unique_email do
    "member-#{System.unique_integer([:positive])}@example.com"
  end
end
