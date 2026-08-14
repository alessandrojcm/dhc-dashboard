defmodule Dhc.E2EHarness do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Auth.UserRole

  alias Dhc.Discord.{
    IdentityBindingHistory,
    IdentityRecovery,
    IdentityRecoveryCase,
    IdentityRecoveryProof,
    SignedManifest
  }

  alias Dhc.Invitations.Invitation
  alias Dhc.Inventory.Categories
  alias Dhc.Inventory.Containers
  alias Dhc.Inventory.Items
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.MemberFixtures
  alias Dhc.Onboarding.InvitationAcceptanceAttempts
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo
  alias Dhc.Settings.Setting
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.Workshops
  alias Dhc.Workshops.Registration
  alias Dhc.UserProfiles.UserProfile

  def reset! do
    Dhc.E2EOnboardingFinalizer.reset!()
    _ = Dhc.OnboardingE2EStripeAdapter.finish_probe()

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

  def start_onboarding_isolation_probe,
    do: Dhc.OnboardingE2EStripeAdapter.start_probe()

  def invitation_acceptance_assertion(invitation_id) do
    invitation = Repo.get!(Invitation, invitation_id)
    principal_id = invitation.prospective_principal_id
    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation_id)

    %{
      attempts:
        Repo.aggregate(
          from(attempt in InvitationAcceptanceAttempt,
            where: attempt.invitation_id == ^invitation_id
          ),
          :count
        ),
      continuations:
        Repo.aggregate(
          from(continuation in InvitationAcceptanceDiscordContinuation,
            where: continuation.invitation_id == ^invitation_id
          ),
          :count
        ),
      externalIdentities:
        Repo.aggregate(
          from(identity in Dhc.Auth.ExternalIdentity,
            where: identity.principal_id == ^principal_id
          ),
          :count
        ),
      magicLinksOrSessions:
        Repo.aggregate(
          from(token in PrincipalToken, where: token.principal_id == ^principal_id),
          :count
        ),
      memberProfiles:
        Repo.aggregate(
          from(profile in MemberProfile, where: profile.id == ^principal_id),
          :count
        ),
      obanJobs:
        Repo.aggregate(
          from(job in "oban_jobs",
            where: fragment("?->>'attempt_id' = ?", field(job, :args), ^attempt.id)
          ),
          :count
        ),
      principals:
        Repo.aggregate(
          from(principal in Dhc.Auth.Principal, where: principal.id == ^principal_id),
          :count
        ),
      roles:
        Repo.aggregate(
          from(role in UserRole, where: role.principal_id == ^principal_id),
          :count
        ),
      stripeCustomerId: attempt.stripe_customer_id,
      stripeInvocations: Dhc.OnboardingE2EStripeAdapter.finish_probe(),
      stripeState: attempt.stripe_state,
      userProfiles:
        Repo.aggregate(
          from(profile in UserProfile, where: profile.principal_id == ^principal_id),
          :count
        )
    }
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

  def seed("identityRecovery", attrs) do
    operation = Map.get(attrs, "operation", "replacement")
    suffix = System.unique_integer([:positive])
    source = MemberFixtures.member_fixture(%{email: "recovery-source-#{suffix}@example.com"})

    destination =
      MemberFixtures.member_fixture(%{email: "recovery-destination-#{suffix}@example.com"})

    first_approver =
      MemberFixtures.member_fixture(%{email: "recovery-admin-#{suffix}@example.com"})

    second_approver =
      MemberFixtures.member_fixture(%{email: "recovery-president-#{suffix}@example.com"})

    Repo.insert!(%UserRole{principal_id: first_approver.principal_id, role: "admin"})
    Repo.insert!(%UserRole{principal_id: second_approver.principal_id, role: "president"})

    source_subject = "e2e-recovery-source-#{suffix}"

    incoming_subject =
      if operation == "transfer", do: source_subject, else: "e2e-recovery-incoming-#{suffix}"

    source_principal = Auth.get_principal!(source.principal_id)

    source_identity =
      %ExternalIdentity{}
      |> ExternalIdentity.create_changeset(source_principal, %{
        provider: "discord",
        provider_subject: source_subject,
        metadata: %{}
      })
      |> Repo.insert!()

    fingerprint_key = Application.fetch_env!(:dhc, :discord_subject_fingerprint_key)
    manifest_key = "e2e-identity-recovery-manifest-key"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    open_command = %{
      "version" => 1,
      "action" => "open",
      "issued_at" => DateTime.to_iso8601(now),
      "binding_id" => source_identity.id,
      "binding_fingerprint" => recovery_fingerprint(source_subject, fingerprint_key),
      "reporter_reference" => "e2e-recovery-#{suffix}",
      "reason_code" => "replacement_request",
      "evidence_references" => ["e2e-evidence-#{suffix}"],
      "actor_principal_id" => first_approver.principal_id
    }

    {:ok, receipt} =
      IdentityRecovery.open_signed(SignedManifest.sign(open_command, manifest_key), %{
        manifest_key: manifest_key,
        fingerprint_key: fingerprint_key,
        now: now
      })

    {:ok, ^receipt} =
      IdentityRecovery.record_discord_oauth_proof(
        receipt.case_reference,
        %{"sub" => incoming_subject},
        fingerprint_key
      )

    recovery_case = Repo.get_by!(IdentityRecoveryCase, case_reference: receipt.case_reference)
    destination_principal = Auth.get_principal!(destination.principal_id)

    {token, token_row} =
      PrincipalToken.build_identity_recovery_token(destination_principal, recovery_case.id)

    Repo.insert!(token_row)

    %{
      caseReference: receipt.case_reference,
      destinationEmail: destination_principal.email,
      proofUrl:
        "/auth/identity-recovery?caseReference=#{URI.encode_www_form(receipt.case_reference)}&token=#{URI.encode_www_form(token)}",
      operation: operation,
      sourcePrincipalId: source.principal_id,
      destinationPrincipalId: destination.principal_id,
      firstApproverId: first_approver.principal_id,
      secondApproverId: second_approver.principal_id
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

  def delete_fixture("invitation", id) do
    principal_id =
      Repo.one(from(i in Invitation, where: i.id == ^id, select: i.prospective_principal_id))

    InvitationAcceptanceAttempts.purge_for_invitation(id)
    :ok = Dhc.Invitations.delete_many([id])

    if principal_id, do: delete_principal(principal_id)
    :ok
  end

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

  def invitation_acceptance_audit(invitation_id) do
    principal_id =
      Repo.one!(
        from(i in Invitation,
          where: i.id == ^invitation_id,
          select: i.prospective_principal_id
        )
      )

    token_counts =
      Repo.all(
        from(t in PrincipalToken,
          where: t.principal_id == ^principal_id,
          group_by: t.context,
          select: {t.context, count(t.id)}
        )
      )
      |> Map.new()

    attempts =
      Repo.all(
        from(a in InvitationAcceptanceAttempt,
          where: a.invitation_id == ^invitation_id,
          select: %{
            status: a.status,
            stripe_customer_id: a.stripe_customer_id,
            stripe_state: a.stripe_state
          }
        )
      )

    continuation_ids =
      Repo.all(
        from(c in InvitationAcceptanceDiscordContinuation,
          where: c.invitation_id == ^invitation_id,
          select: c.id
        )
      )

    %{
      sessionTokenCount: Map.get(token_counts, "session", 0),
      magicLinkTokenCount: Map.get(token_counts, "login", 0),
      principalCount:
        Repo.aggregate(from(principal in Principal, where: principal.id == ^principal_id), :count),
      userProfileCount:
        Repo.aggregate(
          from(profile in UserProfile, where: profile.principal_id == ^principal_id),
          :count
        ),
      memberRoleCount:
        Repo.aggregate(
          from(role in UserRole,
            where: role.principal_id == ^principal_id and role.role == "member"
          ),
          :count
        ),
      discordIdentityCount:
        Repo.aggregate(
          from(identity in ExternalIdentity,
            where: identity.principal_id == ^principal_id and identity.provider == "discord"
          ),
          :count
        ),
      memberProfileCount:
        Repo.aggregate(
          from(profile in MemberProfile, where: profile.id == ^principal_id),
          :count
        ),
      attemptCount: length(attempts),
      provisionedAttemptCount: Enum.count(attempts, &(&1.status == "provisioned")),
      completedAttemptCount: Enum.count(attempts, &(&1.status == "completed")),
      declinedAttemptCount: Enum.count(attempts, &(&1.status == "declined")),
      continuationCount: length(continuation_ids),
      subjectClaimCount:
        Repo.aggregate(
          from(claim in InvitationAcceptanceDiscordSubjectClaim,
            where: claim.continuation_id in ^continuation_ids
          ),
          :count
        ),
      stripeCustomerCount:
        attempts
        |> Enum.map(& &1.stripe_customer_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length(),
      monthlySubscriptionCount: stripe_progress_count(attempts, "monthly_subscription_id"),
      annualSubscriptionCount: stripe_progress_count(attempts, "annual_subscription_id")
    }
  end

  def interrupt_next_finalization! do
    Dhc.E2EOnboardingFinalizer.interrupt_next!()
  end

  def complete_identity_recovery(case_reference) do
    recovery_case = Repo.get_by!(IdentityRecoveryCase, case_reference: case_reference)

    oauth =
      Repo.get_by!(IdentityRecoveryProof,
        recovery_case_id: recovery_case.id,
        kind: "discord_oauth"
      )

    destination =
      Repo.get_by!(IdentityRecoveryProof,
        recovery_case_id: recovery_case.id,
        kind: "destination_magic_link"
      )

    second_approver_id =
      Repo.one!(
        from(role in UserRole,
          where:
            role.role in ["admin", "president"] and
              role.principal_id != ^recovery_case.actor_principal_id,
          order_by: [desc: role.id],
          limit: 1,
          select: role.principal_id
        )
      )

    approver_ids = [recovery_case.actor_principal_id, second_approver_id]

    operation =
      if recovery_case.binding_fingerprint ==
           recovery_fingerprint(
             oauth.subject,
             Application.fetch_env!(:dhc, :discord_subject_fingerprint_key)
           ),
         do: "transfer",
         else: "replacement"

    command = %{
      "version" => 1,
      "action" => "approve",
      "issued_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "case_reference" => recovery_case.case_reference,
      "source_binding_fingerprint" => recovery_case.binding_fingerprint,
      "destination_principal_id" => destination.principal_id,
      "incoming_subject_fingerprint" => oauth.subject_fingerprint,
      "evidence_references" => recovery_case.evidence_references,
      "operation" => operation
    }

    Enum.each(approver_ids, fn approver_id ->
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _receipt} =
        IdentityRecovery.approve_signed(SignedManifest.sign_ed25519(command, private_key), %{
          approver_public_keys: %{approver_id => public_key},
          now: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end)

    fingerprint_key = Application.fetch_env!(:dhc, :discord_subject_fingerprint_key)

    with {:ok, result} <- IdentityRecovery.complete(case_reference, fingerprint_key) do
      source_identity = Repo.get!(ExternalIdentity, recovery_case.external_identity_id)

      active_identity =
        Repo.one!(
          from(identity in ExternalIdentity,
            where:
              identity.principal_id == ^destination.principal_id and
                identity.provider == "discord" and is_nil(identity.retired_at)
          )
        )

      {:ok,
       %{
         state: result.state,
         operation: result.operation,
         activeDestinationPrincipalId: active_identity.principal_id,
         bindingHistoryCount:
           Repo.aggregate(
             from(history in IdentityBindingHistory,
               where: history.recovery_case_id == ^recovery_case.id
             ),
             :count
           ),
         affectedTokenCount:
           Repo.aggregate(
             from(token in PrincipalToken,
               where:
                 token.principal_id in ^[source_identity.principal_id, destination.principal_id] and
                   token.context in ["session", "socket", "login"]
             ),
             :count
           )
       }}
    end
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

  defp stripe_progress_count(attempts, key) do
    attempts
    |> Enum.map(&Map.get(&1.stripe_state, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
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

  defp recovery_fingerprint(subject, key),
    do: :crypto.mac(:hmac, :sha256, key, subject) |> Base.encode16(case: :lower)
end
