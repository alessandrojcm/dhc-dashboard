defmodule Dhc.E2EHarness do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Auth.UserRole

  alias Dhc.Invitations.Invitation
  alias Dhc.Inventory
  alias Dhc.Inventory.Categories
  alias Dhc.Inventory.Containers
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.MaintenancePeriod
  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Inventory.PropertyOption
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
    Dhc.Onboarding.Finalizer.E2E.reset!()
    _ = Dhc.Onboarding.StripeAdapter.E2E.finish_probe()

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
    do: Dhc.Onboarding.StripeAdapter.E2E.start_probe()

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
      stripeInvocations: Dhc.Onboarding.StripeAdapter.E2E.finish_probe(),
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
        customer_id:
          Map.get(attrs, "customerId", "cus_e2e_#{System.unique_integer([:positive])}"),
        # ALE-252 reactivation fixtures need lapsed members: locally flagged
        # inactive exactly as the Stripe sync leaves them after coverage ends.
        is_active: Map.get(attrs, "isActive", true)
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
        pricing_tier: Map.get(attrs, "pricingTier", "standard"),
        metadata: %{},
        first_name: Map.get(attrs, "firstName", "Test"),
        last_name: Map.get(attrs, "lastName", "Invitee"),
        phone_number: Map.get(attrs, "phoneNumber", "+353810000000"),
        date_of_birth: date_of_birth
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

  # ALE-288 IMPL-01: frozen `inventoryStructure` scenario. Routes through
  # `Dhc.Inventory` only; returns plain camelCase maps, never `*JSON.render/2`
  # output. Creates category → definitions/options in order → nested
  # containers under the actor, atomically (any step failing rolls back).
  def seed("inventoryStructure", attrs) when is_map(attrs) do
    case Repo.transaction(fn -> do_seed_structure!(attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_seed_structure!(attrs) do
    category_name = Map.fetch!(attrs, "categoryName")
    definitions = Map.get(attrs, "definitions", []) || []
    container_path = Map.get(attrs, "containerPath", []) || []
    container_description = Map.get(attrs, "containerDescription")
    actor_id = Map.get(attrs, "actorId")

    if container_path != [] and (actor_id == nil or actor_id == "") do
      raise ArgumentError,
            "inventoryStructure seed requires actorId when containerPath is non-empty"
    end

    category =
      case Inventory.create_category(%{
             "name" => category_name,
             "description" => Map.get(attrs, "categoryDescription")
           }) do
        {:ok, category} -> category
        {:error, :conflict, changeset} -> Repo.rollback({:conflict, changeset})
        {:error, changeset} -> Repo.rollback(changeset)
      end

    Enum.each(definitions, fn definition ->
      seed_structure_definition!(category.id, definition)
    end)

    containers = seed_structure_containers!(container_path, container_description, actor_id)

    %{
      categoryId: category.id,
      categoryName: category.name,
      definitions: structure_definition_results!(category.id),
      containers: containers
    }
  end

  defp seed_structure_definition!(category_id, definition) when is_map(definition) do
    label = Map.fetch!(definition, "label")
    value_type = Map.fetch!(definition, "valueType")
    options = Map.get(definition, "options")

    if value_type == "single_select" and (options == nil or options == []) do
      Repo.rollback({:missing_options, label})
    end

    if value_type != "single_select" and is_list(options) and options != [] do
      Repo.rollback(:not_single_select)
    end

    definition_attrs = %{
      "label" => label,
      "valueType" => value_type,
      "required" => Map.get(definition, "required", false),
      "identifyingPosition" => Map.get(definition, "identifyingPosition")
    }

    definition_id =
      case Inventory.create_definition(category_id, definition_attrs) do
        {:ok, created} -> created.id
        {:error, :not_found} -> Repo.rollback(:category_not_found)
        {:error, :conflict, changeset} -> Repo.rollback({:conflict, changeset})
        {:error, changeset} -> Repo.rollback(changeset)
      end

    if value_type == "single_select" do
      options
      |> Enum.with_index()
      |> Enum.each(fn {option, index} ->
        option_attrs = %{
          "label" => Map.fetch!(option, "label"),
          "position" => Map.get(option, "position", index)
        }

        case Inventory.create_option(definition_id, option_attrs) do
          {:ok, _} -> :ok
          {:error, :not_found} -> Repo.rollback(:definition_not_found)
          {:error, :not_single_select} -> Repo.rollback(:not_single_select)
          {:error, :conflict, changeset} -> Repo.rollback({:conflict, changeset})
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end

    :ok
  end

  defp seed_structure_containers!([], _description, _actor_id), do: []

  defp seed_structure_containers!(path, description, actor_id) when is_list(path) do
    {containers, _parent_id, _path_acc} =
      Enum.reduce(path, {[], nil, []}, fn name, {acc, parent_id, path_acc} ->
        current_path = path_acc ++ [name]
        leaf? = length(current_path) == length(path)

        container_attrs =
          %{
            "name" => name,
            "description" => if(leaf?, do: description, else: nil),
            "parent_container_id" => parent_id
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()

        container =
          case Inventory.create_container(container_attrs, actor_id) do
            {:ok, container} -> container
            {:error, changeset} -> Repo.rollback(changeset)
          end

        result = %{
          containerId: container.id,
          name: container.name,
          parentContainerId: container.parent_container_id,
          path: current_path
        }

        {acc ++ [result], container.id, current_path}
      end)

    containers
  end

  defp structure_definition_results!(category_id) do
    category_id
    |> Inventory.list_definitions()
    |> Enum.map(fn definition ->
      %{
        definitionId: definition.id,
        label: definition.label,
        valueType: definition.value_type,
        required: definition.required,
        identifyingPosition: definition.identifying_position,
        options:
          Enum.map(definition.options, fn option ->
            %{optionId: option.id, label: option.label, position: option.position}
          end)
      }
    end)
  end

  # ALE-288 IMPL-02: frozen `inventoryItem` scenario. Routes through
  # `Dhc.Inventory` only; returns plain camelCase maps, never `*JSON.render/2`
  # output. Creates one physical unit (or a duplicate-label pair) with typed
  # values validated in-transaction, then applies the `inMaintenance` /
  # `archived` presets in that order via `OperatorItemLifecycle` (archive
  # atomically ends the open period). Structure ids come from the
  # `inventoryStructure` seed — never names. `deletable` is a seed-time
  # cleanup signal: `false` once a preset ran (maintenance history is
  # retained; an archived row asserts archived, never absence), `true` for
  # history-free units.
  def seed("inventoryItem", attrs) when is_map(attrs) do
    case Repo.transaction(fn -> do_seed_item!(attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_seed_item!(attrs) do
    actor_id = Map.get(attrs, "actorId")

    if actor_id == nil or actor_id == "" do
      raise ArgumentError, "inventoryItem seed requires actorId"
    end

    category_id = Map.get(attrs, "categoryId")
    container_id = Map.get(attrs, "containerId")
    values = Map.get(attrs, "values", %{}) || %{}
    notes = Map.get(attrs, "notes")
    pair? = Map.get(attrs, "withDuplicateLabel", false) == true
    archived? = Map.get(attrs, "archived", false) == true
    in_maintenance? = Map.get(attrs, "inMaintenance", false) == true

    count = if pair?, do: 2, else: 1

    items =
      Enum.map(1..count//1, fn _ ->
        create_seed_item!(category_id, container_id, values, notes, actor_id)
      end)

    if in_maintenance? do
      Enum.each(items, &start_seed_maintenance!(&1.id, actor_id))
    end

    if archived? do
      Enum.each(items, &archive_seed_item!(&1.id, actor_id))
    end

    deletable = not (archived? or in_maintenance?)

    if pair? do
      %{items: Enum.map(items, &item_seed_row!(&1.id, deletable)), deletable: deletable}
    else
      [item] = items
      item_seed_row!(item.id, deletable)
    end
  end

  defp create_seed_item!(category_id, container_id, values, notes, actor_id) do
    attrs = %{
      "categoryId" => category_id,
      "containerId" => container_id,
      "values" => values,
      "notes" => notes
    }

    try do
      case Inventory.create_operator_item(attrs, actor_id) do
        {:ok, item} -> item
        {:error, :invalid_values, errors} -> Repo.rollback({:invalid_values, errors})
        {:error, reason} -> Repo.rollback(reason)
      end
    rescue
      error in Ecto.InvalidChangesetError -> Repo.rollback(error.changeset)
    end
  end

  defp start_seed_maintenance!(item_id, actor_id) do
    case Inventory.start_operator_item_maintenance(
           item_id,
           %{"reason" => "E2E seed: routine check"},
           actor_id
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp archive_seed_item!(item_id, actor_id) do
    case Inventory.archive_operator_item(item_id, %{}, actor_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp item_seed_row!(item_id, deletable) do
    case Inventory.resolve_operator_item(item_id) do
      {:ok, item} ->
        %{
          itemId: item.id,
          slug: item.slug,
          label: item.label,
          categoryId: item.category_id,
          deletable: deletable
        }

      {:error, :not_found} ->
        Repo.rollback(:item_not_found)
    end
  end

  # ALE-288 IMPL-03: frozen `inventoryLoan` scenario. Single scenario with a
  # `preset` enum, never one scenario per state. Routes through
  # `Dhc.Inventory` only (member request/cancel via `MemberLoans`,
  # approve/reject/cancel/checkout/return via `OperatorLoans`,
  # notification-free — exposure attaches `create_keyed/3` after return,
  # never `Notifications.create/2` here). Returns plain camelCase maps with
  # viewer-neutral ids, never `*JSON.render/2` output. `overdue` is derived
  # in club-calendar days, never a stored flag; the seed fabricates elapsed
  # time with a harness-only backdate. `reminderState` (IMPL-04) is accepted
  # and ignored until that contract lands.
  def seed("inventoryLoan", attrs) when is_map(attrs) do
    case Repo.transaction(fn -> do_seed_loan!(attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_seed_loan!(attrs) do
    preset = Map.get(attrs, "preset")

    unless preset in ~w(requested approved checkedOut returned rejected cancelled overdue competingPair) do
      raise ArgumentError,
            "inventoryLoan seed requires preset requested/approved/checkedOut/returned/rejected/cancelled/overdue/competingPair"
    end

    # IMPL-04 passthrough: accepted and ignored until the reminder contract lands.
    _ = Map.get(attrs, "reminderState")

    case preset do
      "competingPair" -> seed_loan_pair!(attrs)
      _ -> seed_single_loan!(preset, attrs)
    end
  end

  defp seed_single_loan!(preset, attrs) do
    item_ref = Map.get(attrs, "itemId") || Map.get(attrs, "itemSlug")

    if item_ref == nil or item_ref == "" do
      Repo.rollback(:not_found)
    end

    borrower_id = Map.get(attrs, "borrowerMemberId")

    if borrower_id == nil or borrower_id == "" do
      raise ArgumentError, "inventoryLoan seed requires borrowerMemberId"
    end

    if Map.get(attrs, "borrowerMemberIds") != nil do
      raise ArgumentError,
            "inventoryLoan seed takes borrowerMemberId or borrowerMemberIds, never both"
    end

    operator_id = Map.get(attrs, "operatorActorId")
    note = Map.get(attrs, "note")
    today = Dhc.Inventory.ClubCalendar.today()
    {starts_on, due_on} = loan_default_dates!(attrs, today)

    case preset do
      "requested" ->
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        loan_seed_row!(loan_id)

      "approved" ->
        require_operator!(operator_id, preset)
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        approve_seed_loan!(loan_id, note, operator_id)
        loan_seed_row!(loan_id)

      "checkedOut" ->
        require_operator!(operator_id, preset)
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        approve_seed_loan!(loan_id, note, operator_id)
        checkout_seed_loan!(loan_id, operator_id)
        loan_seed_row!(loan_id)

      "returned" ->
        require_operator!(operator_id, preset)
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        approve_seed_loan!(loan_id, note, operator_id)
        checkout_seed_loan!(loan_id, operator_id)
        return_seed_loan!(loan_id, operator_id)
        loan_seed_row!(loan_id)

      "rejected" ->
        require_operator!(operator_id, preset)
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        reject_seed_loan!(loan_id, note, operator_id)
        loan_seed_row!(loan_id)

      "cancelled" ->
        seed_cancelled_loan!(attrs, item_ref, starts_on, due_on, note, borrower_id, operator_id)

      "overdue" ->
        require_operator!(operator_id, preset)
        offset = loan_due_offset!(attrs)
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        approve_seed_loan!(loan_id, note, operator_id)
        checkout_seed_loan!(loan_id, operator_id)
        backdate_overdue_loan!(loan_id, offset, today)
        loan_seed_row!(loan_id)
    end
  end

  defp seed_cancelled_loan!(attrs, item_ref, starts_on, due_on, note, borrower_id, operator_id) do
    cancelled_by = Map.get(attrs, "cancelledBy", "member")

    unless cancelled_by in ~w(member operator) do
      raise ArgumentError, "inventoryLoan cancelledBy must be member or operator"
    end

    case cancelled_by do
      "member" ->
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        cancel_seed_loan!(loan_id, note, borrower_id)
        loan_seed_row!(loan_id)

      "operator" ->
        require_operator!(operator_id, "cancelled")
        loan_id = request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id)
        approve_seed_loan!(loan_id, note, operator_id)
        cancel_operator_seed_loan!(loan_id, note, operator_id)
        loan_seed_row!(loan_id)
    end
  end

  defp seed_loan_pair!(attrs) do
    borrower_ids = Map.get(attrs, "borrowerMemberIds")

    unless is_list(borrower_ids) and length(borrower_ids) == 2 and
             Enum.all?(borrower_ids, &is_binary/1) do
      raise ArgumentError, "inventoryLoan competingPair requires borrowerMemberIds of 2 uuids"
    end

    if Map.get(attrs, "borrowerMemberId") != nil do
      raise ArgumentError,
            "inventoryLoan seed takes borrowerMemberId or borrowerMemberIds, never both"
    end

    item_ref = Map.get(attrs, "itemId") || Map.get(attrs, "itemSlug")

    if item_ref == nil or item_ref == "" do
      Repo.rollback(:not_found)
    end

    note = Map.get(attrs, "note")
    today = Dhc.Inventory.ClubCalendar.today()
    {starts_on, due_on} = loan_default_dates!(attrs, today)
    [first_borrower, second_borrower] = borrower_ids

    first_id = request_seed_loan!(item_ref, starts_on, due_on, note, first_borrower)
    second_id = request_seed_loan!(item_ref, starts_on, due_on, note, second_borrower)

    first_row = loan_seed_row!(first_id)
    second_row = loan_seed_row!(second_id)

    %{loans: [first_row, second_row], itemId: first_row.itemId}
  end

  defp require_operator!(operator_id, _preset)
       when is_binary(operator_id) and operator_id != "",
       do: :ok

  defp require_operator!(_operator_id, preset) do
    raise ArgumentError, "inventoryLoan preset #{preset} requires operatorActorId"
  end

  defp loan_default_dates!(attrs, today) do
    starts_on = Map.get(attrs, "startsOn") || Date.to_iso8601(today)

    due_on =
      Map.get(attrs, "dueOn") ||
        case Date.from_iso8601(String.slice(starts_on, 0, 10)) do
          {:ok, starts_date} -> starts_date |> Date.add(7) |> Date.to_iso8601()
          {:error, _} -> today |> Date.add(7) |> Date.to_iso8601()
        end

    {starts_on, due_on}
  end

  defp loan_due_offset!(attrs) do
    offset = Map.get(attrs, "dueOffsetDays", 3)

    if is_integer(offset) and offset > 0 do
      offset
    else
      raise ArgumentError, "inventoryLoan dueOffsetDays must be an integer > 0"
    end
  end

  defp request_seed_loan!(item_ref, starts_on, due_on, note, borrower_id) do
    case Inventory.request_loan(
           item_ref,
           %{"startsOn" => starts_on, "dueOn" => due_on, "note" => note},
           borrower_id
         ) do
      {:ok, loan} -> loan.id
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp approve_seed_loan!(loan_id, note, operator_id) do
    case Inventory.approve_loan(loan_id, %{"note" => note}, operator_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reject_seed_loan!(loan_id, note, operator_id) do
    case Inventory.reject_loan(loan_id, %{"note" => note}, operator_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp checkout_seed_loan!(loan_id, operator_id) do
    case Inventory.check_out_loan(loan_id, %{}, operator_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp return_seed_loan!(loan_id, operator_id) do
    case Inventory.return_loan(loan_id, operator_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_seed_loan!(loan_id, note, borrower_id) do
    case Inventory.cancel_loan(loan_id, %{"note" => note}, borrower_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_operator_seed_loan!(loan_id, note, operator_id) do
    case Inventory.cancel_operator_loan(loan_id, %{"note" => note}, operator_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Harness-only time-travel write: simulates elapsed wall-clock time the seed
  # cannot otherwise produce, because checkout gates to a window containing
  # today while overdue needs a due date in the past. Not a domain command.
  defp backdate_overdue_loan!(loan_id, offset_days, today) do
    new_due = Date.add(today, -offset_days)

    loan =
      case Repo.get(Loan, loan_id) do
        nil -> Repo.rollback(:not_found)
        %Loan{} = loan -> loan
      end

    new_start =
      case loan.approved_start_on do
        %Date{} = start ->
          if Date.compare(start, new_due) == :gt, do: Date.add(new_due, -7), else: start

        nil ->
          Date.add(new_due, -7)
      end

    {:ok, handover_at, _offset} =
      "#{Date.to_iso8601(new_due)}T12:00:00Z" |> DateTime.from_iso8601()

    handover_at = DateTime.truncate(handover_at, :second)

    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2, checked_out_at = $3 WHERE id = $4",
      [new_start, new_due, handover_at, Ecto.UUID.dump!(loan_id)]
    )

    :ok
  end

  defp loan_seed_row!(loan_id) do
    today = Dhc.Inventory.ClubCalendar.today()

    case Repo.get(Loan, loan_id) do
      nil ->
        Repo.rollback(:not_found)

      %Loan{} = loan ->
        starts_on = loan.approved_start_on || loan.requested_start_on
        due_on = loan.approved_due_on || loan.requested_due_on

        %{
          loanId: loan.id,
          status: loan.status,
          overdue: loan_overdue?(loan, today),
          itemId: loan.item_id,
          slug: loan.item_slug_snapshot,
          borrowerMemberId: loan.borrower_principal_id,
          startsOn: Date.to_iso8601(starts_on),
          dueOn: Date.to_iso8601(due_on),
          containerPath: loan_member_container_path(loan),
          decidedBy: loan.decided_by_principal_id
        }
    end
  end

  defp loan_overdue?(%Loan{status: "checked_out", approved_due_on: %Date{} = due_on}, today),
    do: Date.compare(today, due_on) == :gt

  defp loan_overdue?(%Loan{}, _today), do: false

  # Member-visible rule (story 15/45): the approval snapshot for approved and
  # later; null before approval so specs assert absence, even though the
  # operator projection technically carries a snapshot.
  defp loan_member_container_path(%Loan{
         status: status,
         approved_container_path_snapshot: path
       })
       when status in ~w(approved checked_out returned),
       do: path

  defp loan_member_container_path(%Loan{}), do: nil

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

  # Teardown for the frozen structure scenario. Accepts either a category id
  # (retires options/definitions, then deletes the category) or a container
  # id (hard-deletes that container). Containers carry no category FK, so a
  # full teardown is multi-call leaf-first: delete containers deepest-first,
  # then the category — matching the integration teardown order. Blocked
  # deletions (`:still_referenced`) surface instead of cascading; callers
  # delete items first.
  #
  # Domain gap (disclosed): `inventory_property_definitions.category_id` is
  # `on_delete: :nothing`, so `Categories.delete_category/1` raises unless
  # every definition row is gone — but the domain offers only `retire_*`
  # (rows stay). A history-free seed therefore cannot tear down through the
  # seam alone. After retiring, the harness hard-deletes definition/option
  # rows **iff zero `item_property_values` reference them (active or
  # archived)** — provably history-free, so no retained fact is destroyed.
  # Any referencing value (even archived-only) stops the teardown with
  # `:still_referenced` instead, preserving the retention rule.
  def delete_fixture("inventoryStructure", id) when is_binary(id) do
    case Inventory.get_category(id) do
      {:ok, _} -> delete_structure_category!(id)
      {:error, :not_found} -> Inventory.delete_container(id)
    end
  end

  defp delete_structure_category!(category_id) do
    with :ok <- retire_structure_definitions!(category_id),
         :ok <- hard_delete_value_free_definitions!(category_id),
         {:ok, _} <- Inventory.delete_category(category_id) do
      :ok
    end
  end

  defp retire_structure_definitions!(category_id) do
    Enum.reduce_while(
      Inventory.list_definitions(category_id),
      :ok,
      fn definition, :ok ->
        case retire_structure_options!(definition.id) do
          :ok ->
            case Inventory.retire_definition(definition.id) do
              {:ok, _} -> {:cont, :ok}
              {:error, :not_found} -> {:cont, :ok}
              {:error, :still_referenced, _} = blocked -> {:halt, blocked}
            end

          {:error, :still_referenced, _} = blocked ->
            {:halt, blocked}
        end
      end
    )
  end

  defp retire_structure_options!(definition_id) do
    Enum.reduce_while(
      Inventory.list_options(definition_id),
      :ok,
      fn option, :ok ->
        case Inventory.retire_option(option.id) do
          {:ok, _} -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, :still_referenced, _} = blocked -> {:halt, blocked}
        end
      end
    )
  end

  defp hard_delete_value_free_definitions!(category_id) do
    Enum.reduce_while(
      Inventory.list_definitions(category_id),
      :ok,
      fn definition, :ok ->
        case hard_delete_value_free_options!(definition.id) do
          :ok ->
            case hard_delete_value_free_definition!(definition.id) do
              :ok -> {:cont, :ok}
              {:error, _, _} = blocked -> {:halt, blocked}
              {:error, _} = error -> {:halt, error}
            end

          {:error, _, _} = blocked ->
            {:halt, blocked}

          {:error, _} = error ->
            {:halt, error}
        end
      end
    )
  end

  defp hard_delete_value_free_options!(definition_id) do
    Enum.reduce_while(
      Inventory.list_options(definition_id),
      :ok,
      fn option, :ok ->
        if option_values_exist?(option.id) do
          {:halt, {:error, :still_referenced, %{active_value_count: 1}}}
        else
          case Repo.get(PropertyOption, option.id) do
            nil ->
              {:cont, :ok}

            record ->
              case Repo.delete(record) do
                {:ok, _} -> {:cont, :ok}
                {:error, changeset} -> {:halt, {:error, changeset}}
              end
          end
        end
      end
    )
  end

  defp hard_delete_value_free_definition!(definition_id) do
    if definition_values_exist?(definition_id) do
      {:error, :still_referenced, %{active_value_count: 1}}
    else
      case Repo.get(PropertyDefinition, definition_id) do
        nil -> :ok
        record -> hard_delete_definition_record!(record)
      end
    end
  end

  defp hard_delete_definition_record!(record) do
    case Repo.delete(record) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp definition_values_exist?(definition_id) do
    from(v in ItemPropertyValue, where: v.property_definition_id == ^definition_id)
    |> Repo.exists?()
  end

  defp option_values_exist?(option_id) do
    from(v in ItemPropertyValue, where: v.option_id == ^option_id)
    |> Repo.exists?()
  end

  # Teardown for the frozen item scenario. History-free items hard-delete via
  # `delete_operator_item/2` with explicit confirmation (value rows + item
  # row; asserts row absence). Items with retained loan or maintenance rows
  # archive instead — `archive_operator_item/3` is idempotent, so an already
  # archived seed is a no-op and teardown asserts `archived_at`, never row
  # absence. A live loan blocking archival surfaces `:loan_active`; the
  # caller closes loans first. Pair seeds delete each `items[]` entry
  # individually. Loans, periods, categories, and containers are never
  # deleted on the caller's behalf.
  def delete_fixture("inventoryItem", id) when is_binary(id) do
    case Inventory.delete_operator_item(id, %{"confirm" => true}) do
      {:ok, _} ->
        if Repo.get(Item, id) == nil, do: :ok, else: {:error, :not_deleted}

      {:error, :has_history} ->
        archive_seed_teardown!(id)

      {:error, _} = error ->
        error
    end
  end

  defp archive_seed_teardown!(id) do
    case Inventory.resolve_operator_item(id) do
      {:error, :not_found} = error -> error
      {:ok, item} -> archive_resolved_item!(id, item)
    end
  end

  defp archive_resolved_item!(_id, %{created_by: nil}), do: {:error, :missing_actor}

  defp archive_resolved_item!(id, %{created_by: actor_id}) do
    with {:ok, _} <- Inventory.archive_operator_item(id, %{}, actor_id),
         {:ok, archived} <- Inventory.resolve_operator_item(id) do
      if archived.archived_at == nil, do: {:error, :not_archived}, else: :ok
    end
  end

  defp item_has_history?(item_id) do
    loans? = from(loan in Loan, where: loan.item_id == ^item_id) |> Repo.exists?()

    periods? =
      from(period in MaintenancePeriod, where: period.item_id == ^item_id) |> Repo.exists?()

    loans? or periods?
  end

  # Teardown for the frozen loan scenario. Retention says loan records are
  # permanent with no domain delete — E2E teardown breaks this deliberately
  # and narrowly: hard-deletes the loan row directly (both `competingPair`
  # entries deleted individually — no bulk pair delete) and asserts row
  # absence. Never cascades: items, members, periods, categories, and
  # containers are left untouched. Production retention is unaffected — no
  # domain delete function is created to serve this.
  def delete_fixture("inventoryLoan", id) when is_binary(id) do
    case Repo.get(Loan, id) do
      nil ->
        {:error, :not_found}

      loan ->
        case Repo.delete(loan) do
          {:ok, _} ->
            if Repo.get(Loan, id) == nil, do: :ok, else: {:error, :not_deleted}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

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

  # Partial update for the frozen structure scenario. Accepts the seed's
  # field names plus ids targeting existing rows: optional `categoryName` /
  # `categoryDescription`, id-keyed `definitions` (each with `definitionId`
  # plus `label` / `required` / `identifyingPosition` / id-keyed `options`),
  # and id-keyed `containers` (each with `containerId` plus `name` /
  # `description`). Container moves are excluded — `parentContainerId`
  # changes are ignored; moves go through `Containers.move_container/2`.
  # Domain refusals (`:type_immutable`, `:required_blocked`, conflicts)
  # pass through as error tuples. Returns the seed result shape for the
  # touched rows (containers echo only the ids listed in attrs).
  def update_fixture("inventoryStructure", category_id, attrs) when is_map(attrs) do
    with :ok <- update_structure_category!(category_id, attrs),
         :ok <- update_structure_definitions!(attrs),
         :ok <- update_structure_containers!(attrs) do
      case Inventory.get_category(category_id) do
        {:ok, category} ->
          %{
            categoryId: category.id,
            categoryName: category.name,
            definitions: structure_definition_results!(category.id),
            containers: structure_updated_containers!(attrs)
          }

        {:error, :not_found} = error ->
          error
      end
    end
  end

  defp update_structure_category!(category_id, attrs) do
    updates =
      %{}
      |> maybe_put("name", attrs, "categoryName")
      |> maybe_put("description", attrs, "categoryDescription")

    if updates == %{} do
      :ok
    else
      case Inventory.update_category(category_id, updates) do
        {:ok, _} -> :ok
        {:error, :not_found} = error -> error
        {:error, :conflict, _} = error -> error
        {:error, _} = error -> error
      end
    end
  end

  defp update_structure_definitions!(attrs) do
    case Map.get(attrs, "definitions") do
      nil ->
        :ok

      definitions when is_list(definitions) ->
        Enum.reduce_while(definitions, :ok, fn definition, :ok ->
          case update_one_structure_definition!(definition) do
            :ok -> {:cont, :ok}
            {:error, _, _} = error -> {:halt, error}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp update_one_structure_definition!(definition) when is_map(definition) do
    definition_id = Map.fetch!(definition, "definitionId")

    updates =
      %{}
      |> maybe_put("label", definition, "label")
      |> maybe_put("value_type", definition, "valueType")
      |> maybe_put("required", definition, "required")
      |> maybe_put("identifying_position", definition, "identifyingPosition")

    with :ok <- apply_definition_updates!(definition_id, updates),
         :ok <- update_structure_options!(definition) do
      :ok
    end
  end

  defp apply_definition_updates!(_definition_id, updates) when updates == %{}, do: :ok

  defp apply_definition_updates!(definition_id, updates) do
    case Inventory.update_definition(definition_id, updates) do
      {:ok, _} -> :ok
      {:error, :not_found} = error -> error
      {:error, :type_immutable} = error -> error
      {:error, :required_blocked, _} = error -> error
      {:error, :conflict, _} = error -> error
      {:error, _} = error -> error
    end
  end

  defp update_structure_options!(definition) do
    case Map.get(definition, "options") do
      nil ->
        :ok

      options when is_list(options) ->
        Enum.reduce_while(options, :ok, fn option, :ok ->
          option_id = Map.fetch!(option, "optionId")

          updates =
            %{}
            |> maybe_put("label", option, "label")
            |> maybe_put("position", option, "position")

          if updates == %{} do
            {:cont, :ok}
          else
            case Inventory.update_option(option_id, updates) do
              {:ok, _} -> {:cont, :ok}
              {:error, :not_found} = error -> {:halt, error}
              {:error, :conflict, _} = error -> {:halt, error}
              {:error, _} = error -> {:halt, error}
            end
          end
        end)
    end
  end

  defp update_structure_containers!(attrs) do
    case Map.get(attrs, "containers") do
      nil ->
        :ok

      containers when is_list(containers) ->
        Enum.reduce_while(containers, :ok, fn container, :ok ->
          container_id = Map.fetch!(container, "containerId")

          updates =
            %{}
            |> maybe_put("name", container, "name")
            |> maybe_put("description", container, "description")

          if updates == %{} do
            {:cont, :ok}
          else
            case Inventory.update_container(container_id, updates) do
              {:ok, _} -> {:cont, :ok}
              {:error, :not_found} = error -> {:halt, error}
              {:error, _} = error -> {:halt, error}
            end
          end
        end)
    end
  end

  defp structure_updated_containers!(attrs) do
    case Map.get(attrs, "containers") do
      nil ->
        []

      containers when is_list(containers) ->
        Enum.map(containers, fn container ->
          container_id = Map.fetch!(container, "containerId")
          {:ok, fresh} = Inventory.get_container(container_id)

          %{
            containerId: fresh.id,
            name: fresh.name,
            parentContainerId: fresh.parent_container_id,
            path: structure_container_path!(fresh)
          }
        end)
    end
  end

  defp structure_container_path!(container) do
    case container.parent_container_id do
      nil ->
        [container.name]

      parent_id ->
        {:ok, parent} = Inventory.get_container(parent_id)
        structure_container_path!(parent) ++ [container.name]
    end
  end

  # Partial update for the frozen item scenario. Accepts `notes` + `values`
  # only, mapping to `OperatorItems.update_operator_item/3`: supplying
  # `values` replaces the complete set, omitting it leaves stored values
  # untouched. `containerId` / `categoryId` / preset flags are never applied
  # (movement and reclassification are handoff 04 commands, not generic
  # edits). Edits on an archived item (`:archived`) and value failures
  # (`:invalid_values`) pass through. Returns the flat seed row; `deletable`
  # reflects retained history and archive state.
  def update_fixture("inventoryItem", id, attrs) when is_map(attrs) do
    case Inventory.resolve_operator_item(id) do
      {:error, :not_found} = error ->
        error

      {:ok, current} ->
        actor_id = Map.get(attrs, "actorId") || current.created_by

        if actor_id == nil do
          {:error, :missing_actor}
        else
          update_seed_item!(id, attrs, actor_id)
        end
    end
  end

  defp update_seed_item!(id, attrs, actor_id) do
    update_attrs =
      %{}
      |> maybe_put("notes", attrs, "notes")
      |> maybe_put("values", attrs, "values")

    case Inventory.update_operator_item(id, update_attrs, actor_id) do
      {:ok, item} ->
        deletable = not item_has_history?(item.id) and is_nil(item.archived_at)

        %{
          itemId: item.id,
          slug: item.slug,
          label: item.label,
          categoryId: item.category_id,
          deletable: deletable
        }

      {:error, :invalid_values, errors} ->
        {:error, {:invalid_values, errors}}

      {:error, _} = error ->
        error
    end
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
            id: a.id,
            status: a.status,
            stripe_customer_id: a.stripe_customer_id,
            stripe_state: a.stripe_state,
            last_error: a.last_error,
            operation_active: not is_nil(a.operation_token)
          }
        )
      )

    attempt_ids = Enum.map(attempts, & &1.id)

    recovery_jobs =
      Repo.all(
        from(job in Oban.Job,
          where:
            job.worker == "Dhc.Onboarding.Workers.AcceptanceRecoveryWorker" and
              job.args["attempt_id"] in ^attempt_ids,
          select: %{
            id: job.id,
            state: job.state,
            args: job.args,
            attempt: job.attempt,
            scheduled_at: job.scheduled_at,
            errors: job.errors
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
      attempts:
        Enum.map(attempts, fn attempt ->
          %{
            id: attempt.id,
            status: attempt.status,
            lastError: attempt.last_error,
            operationActive: attempt.operation_active
          }
        end),
      recoveryJobs: recovery_jobs,
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

  def interrupt_next_finalization!(invitation_id) do
    attempt =
      Repo.one!(
        from(a in InvitationAcceptanceAttempt,
          where:
            a.invitation_id == ^invitation_id and
              a.status in ["processing", "payment_pending", "provisioned"],
          order_by: [desc: a.created_at],
          limit: 1
        )
      )

    Dhc.Onboarding.Finalizer.E2E.interrupt!(attempt.id)
  end

  def clear_finalization_interruption!(invitation_id) do
    from(a in InvitationAcceptanceAttempt,
      where: a.invitation_id == ^invitation_id,
      select: a.id
    )
    |> Repo.all()
    |> Enum.each(&Dhc.Onboarding.Finalizer.E2E.clear!/1)

    :ok
  end

  defp delete_principal(id) do
    Repo.transaction(fn ->
      Repo.delete_all(from(t in PrincipalToken, where: t.principal_id == ^id))
      Repo.delete_all(from(r in UserRole, where: r.principal_id == ^id))

      Repo.update_all(
        from(i in Invitation, where: i.created_by_principal_id == ^id),
        set: [created_by_principal_id: nil]
      )

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
end
