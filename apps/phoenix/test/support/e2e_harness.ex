defmodule Dhc.E2EHarness do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Auth.UserRole
  alias Dhc.Invitations.Invitation
  alias Dhc.Inventory.Categories
  alias Dhc.Inventory.Containers
  alias Dhc.Inventory.Items
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.MemberFixtures
  alias Dhc.Repo
  alias Dhc.Settings.Setting
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.Workshops
  alias Dhc.Workshops.Registration
  alias Dhc.UserProfiles.UserProfile

  def reset! do
    %{rows: [[tables]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT string_agg(quote_ident(tablename), ', ') FROM pg_tables WHERE schemaname = 'public' AND tablename != 'schema_migrations'",
        []
      )

    if is_binary(tables) and tables != "" do
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE TABLE #{tables} RESTART IDENTITY CASCADE", [])
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(Setting, [
      %{key: "waitlist_open", value: "true", type: "boolean", created_at: now, updated_at: now},
      %{
        key: "hema_insurance_form_link",
        value: "https://example.com/insurance",
        type: "text",
        created_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  def seed("member", attrs) do
    email = Map.fetch!(attrs, "email")

    member =
      MemberFixtures.member_fixture(%{
        email: email,
        first_name: Map.get(attrs, "firstName", "Test"),
        last_name: Map.get(attrs, "lastName", "Member"),
        phone_number: Map.get(attrs, "phoneNumber", "+353810000000"),
        date_of_birth: parse_date(Map.get(attrs, "dateOfBirth"), ~D[1990-01-01]),
        gender: Map.get(attrs, "gender", "man (cis)"),
        pronouns: Map.get(attrs, "pronouns", "they/them"),
        medical_conditions: Map.get(attrs, "medicalConditions", "None"),
        customer_id: Map.get(attrs, "customerId", "cus_e2e_#{System.unique_integer([:positive])}")
      })

    roles = Map.get(attrs, "roles", ["member"]) |> Enum.uniq()

    Repo.insert_all(
      UserRole,
      Enum.map(roles, &%{principal_id: member.principal_id, role: &1}),
      on_conflict: :nothing
    )

    from(m in MemberProfile, where: m.id == ^member.principal_id)
    |> Repo.update_all(set: [insurance_form_submitted: true])

    %{
      email: email,
      memberId: member.principal_id,
      userId: member.principal_id,
      profileId: member.profile_id,
      customerId: member.customer_id
    }
  end

  def seed("waitlist", attrs) do
    email = Map.fetch!(attrs, "email")

    payload = %{
      "firstName" => Map.get(attrs, "firstName", "Test"),
      "lastName" => Map.get(attrs, "lastName", "Waitlist"),
      "email" => email,
      "dateOfBirth" => Map.get(attrs, "dateOfBirth", "1990-01-01") |> String.slice(0, 10),
      "phoneNumber" => Map.get(attrs, "phoneNumber", "+353810000000"),
      "pronouns" => Map.get(attrs, "pronouns", "they/them"),
      "gender" => Map.get(attrs, "gender", "non-binary"),
      "medicalConditions" => Map.get(attrs, "medicalConditions", "None"),
      "socialMediaConsent" => Map.get(attrs, "socialMediaConsent", "no")
    }

    payload =
      case Map.get(attrs, "guardian") do
        nil ->
          payload

        guardian ->
          payload
          |> Map.put("guardianFirstName", Map.get(guardian, "firstName"))
          |> Map.put("guardianLastName", Map.get(guardian, "lastName"))
          |> Map.put("guardianPhoneNumber", Map.get(guardian, "phoneNumber"))
      end

    with {:ok, result} <- Waitlist.create_entry(payload) do
      status = Map.get(attrs, "status", "waiting")

      from(w in WaitlistEntry, where: w.id == ^result.id)
      |> Repo.update_all(set: [status: status])

      Map.merge(result, %{email: email, waitlistId: result.id, profileId: result.profile_id})
    end
  end

  def seed("invitation", attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    status = Map.get(attrs, "status", "pending")

    expires_at =
      if status == "expired", do: DateTime.add(now, -60), else: DateTime.add(now, 86_400)

    date_of_birth = parse_date(Map.get(attrs, "dateOfBirth"), ~D[1990-01-01])

    invitation =
      %Invitation{prospective_principal_id: Ecto.UUID.generate()}
      |> Invitation.changeset(%{
        email: Map.fetch!(attrs, "email"),
        status: status,
        expires_at: expires_at,
        invitation_type: Map.get(attrs, "invitationType", "admin"),
        metadata: %{},
        first_name: Map.get(attrs, "firstName", "Test"),
        last_name: Map.get(attrs, "lastName", "Invitee"),
        phone_number: Map.get(attrs, "phoneNumber", "+353810000000"),
        date_of_birth: date_of_birth,
        stripe_customer_id: Map.get(attrs, "customerId")
      })
      |> Repo.insert!()

    %{
      invitationId: invitation.id,
      email: invitation.email,
      dateOfBirth: Date.to_iso8601(date_of_birth),
      userId: invitation.prospective_principal_id
    }
  end

  def seed("workshop", attrs) do
    created_by = Map.fetch!(attrs, "createdBy")
    {:ok, workshop} = Workshops.create_workshop(workshop_attrs(attrs), created_by)
    workshop = force_workshop_status(workshop, Map.get(attrs, "status", "planned"))
    workshop_dto(workshop)
  end

  def seed("inventoryCategory", attrs) do
    {:ok, category} = Categories.create_category(attrs)
    DhcWeb.InventoryCategoriesJSON.render("show.json", %{category: category}).data
  end

  def seed("inventoryContainer", attrs) do
    actor_id = Map.fetch!(attrs, "actorId")
    {:ok, container} = Containers.create_container(Map.delete(attrs, "actorId"), actor_id)
    DhcWeb.InventoryContainersJSON.render("item.json", %{container: container}).data
  end

  def seed("inventoryItem", attrs) do
    actor_id = Map.fetch!(attrs, "actorId")
    {:ok, item} = Items.create_item(Map.delete(attrs, "actorId"), actor_id)
    DhcWeb.InventoryItemsJSON.render("item.json", %{item: item}).data
  end

  def seed("registration", attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    registration =
      %Registration{}
      |> Registration.fixture_changeset(%{
        club_activity_id: Map.fetch!(attrs, "workshopId"),
        member_user_id: Map.get(attrs, "memberUserId"),
        # ALE-181: display_name is NOT NULL on the registration row.
        display_name: Map.get(attrs, "displayName", "E2E Member"),
        amount_paid: Map.get(attrs, "amountPaid", 0),
        currency: Map.get(attrs, "currency", "eur"),
        status: Map.get(attrs, "status", "confirmed"),
        registered_at: now,
        confirmed_at: now,
        attendance_status: Map.get(attrs, "attendanceStatus", "pending"),
        attendance_notes: Map.get(attrs, "attendanceNotes")
      })
      |> Repo.insert!()

    registration_dto(registration)
  end

  def seed("waitlistStatus", %{"isOpen" => is_open}) do
    {:ok, status} = Waitlist.set_open(is_open)
    %{isOpen: status.is_open}
  end

  def seed("setting", %{"key" => key, "value" => value}) do
    {:ok, setting} = Dhc.Settings.update(key, value)
    %{key: setting.key, value: setting.value}
  end

  def delete_fixture("member", id), do: delete_principal(id)

  def delete_fixture("invitation", id), do: Dhc.Invitations.delete_many([id])

  def delete_fixture("workshop", id) do
    case Repo.get(Dhc.Workshops.Workshop, id) do
      nil ->
        {:error, :not_found}

      workshop ->
        workshop |> force_workshop_status("planned") |> then(&Workshops.delete_workshop(&1.id))
    end
  end

  def delete_fixture("waitlist", id) do
    from(profile in UserProfile, where: profile.waitlist_id == ^id)
    |> Repo.delete_all()

    Waitlist.delete_entry(id)
  end

  def delete_fixture("inventoryCategory", id), do: Categories.delete_category(id)
  def delete_fixture("inventoryContainer", id), do: Containers.delete_container(id)
  def delete_fixture("inventoryItem", id), do: Items.delete_item(id)

  def delete_fixture("registration", id) do
    case Repo.get(Registration, id) do
      nil -> {:error, :not_found}
      registration -> Repo.delete(registration)
    end
  end

  def update_fixture("workshop", id, attrs) do
    {:ok, workshop} = Workshops.update_workshop(id, workshop_attrs(attrs))
    workshop_dto(workshop)
  end

  def update_fixture("registration", id, attrs) do
    registration = Repo.get!(Registration, id)

    registration
    |> Registration.fixture_changeset(registration_attrs(attrs))
    |> Repo.update!()
    |> registration_dto()
  end

  def update_fixture("inventoryCategory", id, attrs) do
    {:ok, category} = Categories.update_category(id, attrs)
    DhcWeb.InventoryCategoriesJSON.render("show.json", %{category: category}).data
  end

  def update_fixture("inventoryContainer", id, attrs) do
    {:ok, container} = Containers.update_container(id, attrs)
    DhcWeb.InventoryContainersJSON.render("item.json", %{container: container}).data
  end

  def update_fixture("inventoryItem", id, %{"actorId" => actor_id} = attrs) do
    {:ok, item} = Items.update_item(id, Map.delete(attrs, "actorId"), actor_id)
    DhcWeb.InventoryItemsJSON.render("item.json", %{item: item}).data
  end

  def login_cookie(email) do
    principal = Auth.get_principal_by_email(email) || raise "No E2E principal for #{email}"
    {token, row} = PrincipalToken.build_session_token(principal)
    Repo.insert!(row)
    token
  end

  defp delete_principal(id) do
    Repo.transaction(fn ->
      Repo.delete_all(from(t in PrincipalToken, where: t.principal_id == ^id))
      Repo.delete_all(from(r in UserRole, where: r.principal_id == ^id))

      profile_ids =
        Repo.all(from(p in UserProfile, where: p.principal_id == ^id, select: p.id))

      Repo.delete_all(from(m in MemberProfile, where: m.user_profile_id in ^profile_ids))
      Repo.delete_all(from(p in UserProfile, where: p.principal_id == ^id))
      Repo.delete_all(from(p in Dhc.Auth.Principal, where: p.id == ^id))
    end)

    :ok
  end

  defp parse_date(nil, fallback), do: fallback
  defp parse_date(value, _fallback), do: value |> String.slice(0, 10) |> Date.from_iso8601!()

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value),
    do: value |> DateTime.from_iso8601() |> elem(1) |> DateTime.truncate(:second)

  defp workshop_attrs(attrs) do
    %{
      title: Map.get(attrs, "title"),
      description: Map.get(attrs, "description"),
      location: Map.get(attrs, "location"),
      start_date: parse_datetime(Map.get(attrs, "startDate")),
      end_date: parse_datetime(Map.get(attrs, "endDate")),
      max_capacity: Map.get(attrs, "maxCapacity"),
      price_member: Map.get(attrs, "priceMember"),
      price_non_member: Map.get(attrs, "priceNonMember"),
      is_public: Map.get(attrs, "isPublic"),
      refund_days: Map.get(attrs, "refundDays"),
      announce_discord: Map.get(attrs, "announceDiscord", false),
      announce_email: Map.get(attrs, "announceEmail", false)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp force_workshop_status(workshop, "planned"), do: workshop

  defp force_workshop_status(workshop, status) do
    workshop
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  defp workshop_dto(workshop) do
    workshop.id
    |> Workshops.workshop_summary()
    |> then(&DhcWeb.WorkshopsJSON.render("management.json", %{workshop: &1}).data.workshop)
  end

  defp registration_attrs(attrs) do
    %{}
    |> maybe_put(:status, attrs, "status")
    |> maybe_put(:attendance_status, attrs, "attendanceStatus")
    |> maybe_put(:attendance_notes, attrs, "attendanceNotes")
  end

  defp registration_dto(registration) do
    %{
      id: registration.id,
      workshopId: registration.club_activity_id,
      memberUserId: registration.member_user_id,
      amountPaid: registration.amount_paid,
      currency: registration.currency,
      status: registration.status,
      attendanceStatus: registration.attendance_status,
      attendanceNotes: registration.attendance_notes
    }
  end

  defp maybe_put(target, target_key, source, source_key) do
    case Map.fetch(source, source_key) do
      {:ok, value} -> Map.put(target, target_key, value)
      :error -> target
    end
  end
end
