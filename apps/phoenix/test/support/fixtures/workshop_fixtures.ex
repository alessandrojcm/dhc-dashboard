defmodule Dhc.WorkshopFixtures do
  @moduledoc """
  Test helpers for creating Workshop persistence rows (Workshops, interests,
  external users, registrations, refunds) for the `Dhc.Workshops` read-model
  tests.

  Inserts go through the Ecto schemas in `Dhc.Workshops.*` so the fixture path
  exercises the same column mappings the read helpers query. Member participants
  reuse `Dhc.MemberFixtures.member_fixture/1` (auth user + user profile + member
  profile); the returned `:auth_user_id` is the Supabase auth user id used as
  both `club_activity_interest.user_id` and
  `club_activity_registrations.member_user_id`.

  Datetime values are truncated to seconds because the Workshop schemas use
  `:utc_datetime`, which rejects microseconds (see AGENTS.md migration notes).
  """

  alias Dhc.MemberFixtures
  alias Dhc.Repo
  alias Dhc.Workshops.{ExternalUser, Refund, Registration, Workshop, WorkshopInterest}

  @doc """
  Inserts a Workshop (a `club_activities` row).

  ## Options

    * `:title` (default `"Test Workshop"`)
    * `:location` (default `"Test Location"`)
    * `:description` (default `"A test workshop"`)
    * `:start_date` / `:end_date` (default now + 7 days / + 7 days 2h)
    * `:max_capacity` (default `20`)
    * `:price_member` / `:price_non_member` (default `1000.0` / `2000.0`, cents)
    * `:is_public` (default `false`)
    * `:refund_days` (default `3`)
    * `:status` (default `"planned"`)
    * `:announce_discord` / `:announce_email` (default `false`)
    * `:created_by` (default `nil`; must be a real `auth.users` id if set)

  Returns the inserted `Workshop` struct.
  """
  def workshop_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    default_start = DateTime.add(now, 7 * 24 * 60 * 60, :second)
    default_end = DateTime.add(default_start, 2 * 60 * 60, :second)

    {:ok, workshop} =
      %Workshop{
        title: Map.get(attrs, :title, "Test Workshop"),
        description: Map.get(attrs, :description, "A test workshop"),
        location: Map.get(attrs, :location, "Test Location"),
        start_date: Map.get(attrs, :start_date, default_start),
        end_date: Map.get(attrs, :end_date, default_end),
        max_capacity: Map.get(attrs, :max_capacity, 20),
        price_member: Map.get(attrs, :price_member, 1000.0),
        price_non_member: Map.get(attrs, :price_non_member, 2000.0),
        is_public: Map.get(attrs, :is_public, false),
        refund_days: Map.get(attrs, :refund_days, 3),
        status: Map.get(attrs, :status, "planned"),
        announce_discord: Map.get(attrs, :announce_discord, false),
        announce_email: Map.get(attrs, :announce_email, false),
        created_by: Map.get(attrs, :created_by)
      }
      |> Repo.insert()

    workshop
  end

  @doc """
  Inserts a `club_activity_interest` row expressing `user_id`'s interest in
  the given Workshop.
  """
  def interest_fixture(workshop_id, user_id) do
    {:ok, interest} =
      %WorkshopInterest{
        club_activity_id: workshop_id,
        user_id: user_id
      }
      |> Repo.insert()

    interest
  end

  @doc """
  Inserts an `external_users` row.

  ## Options

    * `:first_name` / `:last_name` (default `"External"` / `"Guest"`)
    * `:email` (default a unique generated email)
    * `:phone_number` (default `nil`)

  Returns the inserted `ExternalUser` struct.
  """
  def external_user_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {:ok, external_user} =
      %ExternalUser{
        first_name: Map.get(attrs, :first_name, "External"),
        last_name: Map.get(attrs, :last_name, "Guest"),
        email: Map.get(attrs, :email, unique_external_email()),
        phone_number: Map.get(attrs, :phone_number)
      }
      |> Repo.insert()

    external_user
  end

  @doc """
  Inserts a `club_activity_registrations` row.

  Exactly one of `:member_user_id` or `:external_user_id` must be set (the
  table has a CHECK constraint enforcing this).

  ## Options

    * `:workshop_id` (required) — the Workshop id
    * `:member_user_id` — the member's Supabase auth user id (for member regs)
    * `:external_user_id` — the external user id (for external regs)
    * `:status` (default `"pending"`)
    * `:amount_paid` (default `1000`, cents)
    * `:currency` (default `"eur"`)
    * `:attendance_status` (default `"pending"`)
    * `:registered_at` (default now)
    * `:confirmed_at` (default `nil`)
    * `:created_at` (default auto-filled by Ecto timestamps; override to make
      `created_at` ordering deterministic in tests)

  Returns the inserted `Registration` struct.
  """
  def registration_fixture(attrs) do
    attrs = Enum.into(attrs, %{})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Ecto timestamps auto-fill `created_at`/`updated_at` only when nil, so an
    # explicit `:created_at` override is respected — used by attendee-ordering
    # tests to avoid same-second ties.
    registration = %Registration{
      club_activity_id: Map.fetch!(attrs, :workshop_id),
      member_user_id: Map.get(attrs, :member_user_id),
      external_user_id: Map.get(attrs, :external_user_id),
      amount_paid: Map.get(attrs, :amount_paid, 1000),
      currency: Map.get(attrs, :currency, "eur"),
      status: Map.get(attrs, :status, "pending"),
      registered_at: Map.get(attrs, :registered_at, now),
      confirmed_at: Map.get(attrs, :confirmed_at),
      attendance_status: Map.get(attrs, :attendance_status, "pending")
    }

    registration =
      case Map.get(attrs, :created_at) do
        nil -> registration
        created_at -> %{registration | created_at: created_at}
      end

    {:ok, registration} = Repo.insert(registration)

    registration
  end

  @doc """
  Inserts a `club_activity_refunds` row for the given registration.

  ## Options

    * `:registration_id` (required)
    * `:refund_amount` (default `1000`, cents)
    * `:refund_reason` (default `"Test refund"`)
    * `:status` (default `"pending"`)
    * `:requested_at` (default now)

  Returns the inserted `Refund` struct.
  """
  def refund_fixture(attrs) do
    attrs = Enum.into(attrs, %{})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, refund} =
      %Refund{
        registration_id: Map.fetch!(attrs, :registration_id),
        refund_amount: Map.get(attrs, :refund_amount, 1000),
        refund_reason: Map.get(attrs, :refund_reason, "Test refund"),
        status: Map.get(attrs, :status, "pending"),
        requested_at: Map.get(attrs, :requested_at, now)
      }
      |> Repo.insert()

    refund
  end

  @doc """
  Convenience: inserts a full member participant (auth user + user profile +
  member profile) and returns the `Dhc.MemberFixtures.member_fixture/1` map
  (`%{auth_user_id, profile_id, customer_id}`). The `auth_user_id` is the
  Supabase auth user id used for interest/registration fixtures.
  """
  def member_fixture(attrs \\ %{}) do
    MemberFixtures.member_fixture(attrs)
  end

  defp unique_external_email do
    "external-#{System.unique_integer([:positive])}@example.com"
  end
end
