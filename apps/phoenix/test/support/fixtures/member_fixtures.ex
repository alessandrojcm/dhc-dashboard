defmodule Dhc.MemberFixtures do
  @moduledoc """
  Test helpers for creating the minimal auth/user/member rows needed by
  Stripe-sync integration tests.
  """

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @doc """
  Inserts an auth user, a user profile, and a member profile.

  Returns a map with `auth_user_id`, `profile_id`, and `customer_id`.

  ## Options

    * `:customer_id` - override the Stripe customer id (default: auto-generated)
    * `:last_payment_date` - set the member profile's last payment date
    * `:is_active` - set the user profile's active flag
    * `:gender` - set the user profile's gender (default: `"man (cis)"`)
    * `:date_of_birth` - set the user profile's date of birth (default: `~D[1990-01-01]`)
    * `:preferred_weapon` - set the member profile's weapon array (default: `["longsword"]`)
    * `:first_name` - override the user profile's first name (default: `"Test"`)
    * `:last_name` - override the user profile's last name (default: `"Member"`)
    * `:pronouns` - override the user profile's pronouns (default: `"he/him"`)
    * `:phone_number` - override the user profile's phone number
    * `:medical_conditions` - override the user profile's medical conditions
    * `:social_media_consent` - override the user profile's consent (default: `"no"`)
    * `:membership_start_date` - override the member profile's membership start date
    * `:membership_end_date` - override the member profile's membership end date
    * `:subscription_paused_until` - set the member profile's pause-until timestamp
  """
  def member_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    auth_user_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    customer_id = Map.get(attrs, :customer_id, "cus_#{System.unique_integer([:positive])}")

    # `auth.users` is Supabase-owned (no Ecto schema); insert raw. Postgrex
    # expects binary UUIDs when bypassing the schema.
    Repo.insert_all(
      "users",
      [
        [
          id: Ecto.UUID.dump!(auth_user_id),
          aud: "authenticated",
          role: "authenticated",
          email: unique_email()
        ]
      ],
      prefix: "auth"
    )

    # user_profiles via the UserProfile schema — Ecto handles the `created_at`
    # timestamp mapping (the schema declares `timestamps(inserted_at: :created_at)`)
    # and autodumps the `:binary_id` PK/FKs from string UUIDs. `search_text` is a
    # generated column, so the schema deliberately doesn't declare it and the
    # insert skips it (Postgres auto-populates it from first_name/last_name).
    {:ok, _profile} =
      %UserProfile{
        id: profile_id,
        supabase_user_id: auth_user_id,
        first_name: Map.get(attrs, :first_name, "Test"),
        last_name: Map.get(attrs, :last_name, "Member"),
        phone_number: Map.get(attrs, :phone_number, "+353810000000"),
        date_of_birth: Map.get(attrs, :date_of_birth, ~D[1990-01-01]),
        gender: Map.get(attrs, :gender, "man (cis)"),
        pronouns: Map.get(attrs, :pronouns, "he/him"),
        is_active: Map.get(attrs, :is_active, true),
        customer_id: customer_id,
        social_media_consent: Map.get(attrs, :social_media_consent, "no"),
        medical_conditions: Map.get(attrs, :medical_conditions)
      }
      |> Repo.insert()

    # member_profiles via the MemberProfile schema. The schema has
    # `:binary_id` primary/foreign keys (autogenerate: false), so pass the
    # string UUIDs explicitly. Datetime values are truncated to seconds to
    # satisfy the schema's `:utc_datetime` type, which rejects microseconds.
    {:ok, _member} =
      %MemberProfile{
        id: auth_user_id,
        user_profile_id: profile_id,
        next_of_kin_name: "Next of Kin",
        next_of_kin_phone: "+353820000000",
        preferred_weapon: Map.get(attrs, :preferred_weapon, ["longsword"]),
        membership_start_date: Map.get(attrs, :membership_start_date, now),
        membership_end_date: truncate_dt(Map.get(attrs, :membership_end_date)),
        last_payment_date: truncate_dt(Map.get(attrs, :last_payment_date)),
        insurance_form_submitted: false,
        additional_data: %{},
        subscription_paused_until: truncate_dt(Map.get(attrs, :subscription_paused_until))
      }
      |> Repo.insert()

    %{
      auth_user_id: auth_user_id,
      profile_id: profile_id,
      customer_id: customer_id
    }
  end

  defp truncate_dt(nil), do: nil
  defp truncate_dt(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp truncate_dt(value), do: value

  defp unique_email do
    "member-#{System.unique_integer([:positive])}@example.com"
  end
end