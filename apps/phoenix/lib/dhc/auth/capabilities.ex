defmodule Dhc.Auth.Capabilities do
  @moduledoc """
  The one role → capability policy (ALE-344).

  Every authorization question Phoenix asks is a **capability** — a name for
  user intent such as `:"inventory.manage"` — and this module is the only place
  that knows which roles hold which capability. Role sets are private module
  attributes; nothing outside this module may compose or compare role names.

  The capability names are the same as the frontend registry in
  `apps/web/src/lib/server/authorization/capabilities.ts` (GH-510). Phoenix is
  authoritative: the session projection carries the capabilities worked out
  here (`for_roles/1`) and the dashboard only applies ownership and
  navigation on top of them.

  Three read paths share the one table:

    * `can?/3` / `authorize/3` — decide a session projection
      (`%{principal:, roles:, is_active:}`) against a capability and an
      optional resource. `RequireSession` (router pipelines) and controllers
      use these.
    * `holds?/2` — reads the principal's role rows; safe inside a transaction
      that already holds the locks it needs (Discord Assignments).
    * `principal_ids_with/2` — every principal holding a capability on an
      **active** profile, the same eligibility a session needs (loan
      notifications).

  ## Ownership

  An owner-scoped capability (`owner_scoped?/1`) is also granted when the
  resource's `owner_principal_id` is the session principal. Denying an
  owner-scoped capability **conceals** the resource (`:not_found`, HTTP 404)
  instead of admitting it exists (`:forbidden`, HTTP 403), matching the
  frontend's `concealed_resource` decision.

  ## Assignment (ALE-379)

  An assignment-scoped capability (`assignment_scoped?/1`, a rule with
  `assigned: true`) is also granted when the session principal is in the
  resource's `assigned_principal_ids` — a Beginners' Workshop's Staff. A
  denial conceals the resource exactly like ownership. Ownership never grants
  an assignment-scoped capability, nor the reverse.

  Owner- and assignment-scoped capabilities need a resource, so router
  pipelines cannot use them (`resource_scoped?/1`); controllers check them.
  """

  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  # ── Role sets (private) ───────────────────────────────────────────────

  # Club officers.
  @officers ~w(president admin committee_coordinator)

  # Officers with billing authority who may mint membership charges
  # (ALE-251/252 reactivation). Deliberately narrower than the member
  # administrators, with no self-service fallback.
  @billing_authority @officers ++ ~w(treasurer)

  # Every committee/coach role that administers members.
  @member_administrators @billing_authority ++
                           ~w(sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

  # Mirrors the corrected registration RLS policy
  # (`20250923100806_fix_workshops_rls.sql`). Deliberately excludes
  # `beginners_coordinator`: the historical registration visibility drift
  # (see the `Dhc.Workshops` moduledoc) must not be reproduced.
  @workshop_coordinators ~w(workshop_coordinator president admin)

  # Equal operator authority over inventory, loans and the loan queue.
  @inventory_operators ~w(quartermaster admin president)

  # Spec story 23: coaches no longer see the whole Waitlist; only the
  # committee and the beginners coordinator work the queue.
  @waitlist_managers @officers ++ ~w(beginners_coordinator)

  # ALE-378: scheduling and running intake is the beginners coordinator's
  # job, with the officers as cover; workshop coordinators and the treasurer
  # are deliberately excluded.
  @beginners_workshop_managers @officers ++ ~w(beginners_coordinator)

  # ALE-380: the coordinator alerts (Batch sent, free seats but nobody
  # waiting) go to the beginners coordinator only. Recipients-only: no route
  # is gated on it, it only names who is notified.
  @beginners_coordinator_alert_recipients ~w(beginners_coordinator)
  # ALE-379: who may be assigned as a Beginners' Workshop's coach. Checked at
  # assignment only; losing the role later keeps the assignment.
  @beginners_workshop_leads ~w(coach)

  # ALE-330: no read/manage split — only the committee shapes club
  # communications.
  @training_announcement_managers ~w(sparring_coordinator coach president admin committee_coordinator)

  # Every authenticated user carries the `member` role.
  @members ~w(member)

  # ── Registry ──────────────────────────────────────────────────────────

  @rules %{
    # Opening or closing the waitlist (`PATCH /waitlist/status`) is an
    # officer decision; the beginners coordinator only reads and works the
    # list.
    "beginners.waitlist.manage": %{roles: @waitlist_managers},
    "beginners.waitlist.toggle": %{roles: @officers},
    # ALE-379: every member may read their own Staff assignments ("My
    # Beginners' Workshops"); an assistant must be able to, so it is also
    # the "active Member" an assistant must be.
    "beginners.workshops.assigned.read": %{roles: @members},
    "beginners.workshops.lead": %{roles: @beginners_workshop_leads},
    "beginners.workshops.manage": %{roles: @beginners_workshop_managers},
    "beginners.workshops.alerts.receive": %{roles: @beginners_coordinator_alert_recipients},
    # Running a workshop (its door view, check-in): the managers by role,
    # anyone else only while on that workshop's Staff.
    "beginners.workshops.run": %{roles: @beginners_workshop_managers, assigned: true},
    "discord.assignments.manage": %{roles: @member_administrators},
    "discord.doctor.use": %{roles: @officers},
    "inventory.manage": %{roles: @inventory_operators},
    "inventory.catalog.read": %{roles: @members},
    "inventory.loans.own.read": %{roles: @members},
    # ADR 0028: emailing the whole membership is an officer decision.
    "member_announcements.send": %{roles: @officers},
    "members.directory.read": %{roles: @member_administrators},
    # ALE-392: the beginners coordinator invites the people who attended a
    # Beginners' Workshop.
    "members.invite": %{roles: @officers ++ ~w(beginners_coordinator)},
    "members.profile.read": %{roles: @member_administrators, owner: true},
    "members.profile.update": %{roles: @member_administrators, owner: true},
    "members.roles.edit": %{roles: ~w(president admin)},
    "members.settings.edit": %{roles: @officers},
    "membership.reactivate": %{roles: @billing_authority},
    "training_announcements.manage": %{roles: @training_announcement_managers},
    "workshops.manage": %{roles: @workshop_coordinators},
    "workshops.own.read": %{roles: @members}
  }

  @capabilities @rules |> Map.keys() |> Enum.sort()

  @type capability :: atom()
  @type resource :: %{
          optional(:owner_principal_id) => String.t() | nil,
          optional(:assigned_principal_ids) => [String.t()]
        }

  @doc "Every capability in the registry, sorted."
  @spec all() :: [capability()]
  def all, do: @capabilities

  @doc "Whether `capability` is in the registry."
  @spec exists?(term()) :: boolean()
  def exists?(capability), do: Map.has_key?(@rules, capability)

  @doc "Whether the capability is also granted to the resource owner."
  @spec owner_scoped?(capability()) :: boolean()
  def owner_scoped?(capability), do: Map.get(rule!(capability), :owner, false)

  @doc "Whether the capability is also granted to the resource's assigned principals."
  @spec assignment_scoped?(capability()) :: boolean()
  def assignment_scoped?(capability), do: Map.get(rule!(capability), :assigned, false)

  @doc """
  Whether deciding the capability needs a resource (owner- or
  assignment-scoped). A router pipeline cannot check such a capability.
  """
  @spec resource_scoped?(capability()) :: boolean()
  def resource_scoped?(capability),
    do: owner_scoped?(capability) or assignment_scoped?(capability)

  @doc """
  The capability names (wire strings, sorted) the given roles hold without
  any resource context. This is what the session projection carries.
  """
  @spec for_roles([String.t()]) :: [String.t()]
  def for_roles(roles) when is_list(roles) do
    for capability <- @capabilities,
        granted_by_role?(capability, roles),
        do: Atom.to_string(capability)
  end

  @doc """
  `true` when the active session projection holds `capability` for
  `resource`. An inactive projection holds nothing.
  """
  @spec can?(map(), capability(), resource()) :: boolean()
  def can?(projection, capability, resource \\ %{}),
    do: authorize(projection, capability, resource) == :ok

  @doc """
  Decides a session projection against a capability (or `nil` for "any
  active session").

  Returns `:ok`, `{:error, :inactive}` (no club access — HTTP 401),
  `{:error, :not_found}` (owner- or assignment-scoped capability denied —
  HTTP 404, the resource is concealed) or `{:error, :forbidden}` (HTTP 403).
  """
  @spec authorize(map(), capability() | nil, resource()) ::
          :ok | {:error, :inactive | :forbidden | :not_found}
  def authorize(projection, capability, resource \\ %{})

  def authorize(%{is_active: true}, nil, _resource), do: :ok

  def authorize(%{is_active: true, roles: roles} = projection, capability, resource) do
    cond do
      granted_by_role?(capability, roles) -> :ok
      not resource_scoped?(capability) -> {:error, :forbidden}
      owner_scoped?(capability) and owner?(projection, resource) -> :ok
      assignment_scoped?(capability) and assigned?(projection, resource) -> :ok
      true -> {:error, :not_found}
    end
  end

  def authorize(_projection, capability, _resource) do
    _ = capability && rule!(capability)
    {:error, :inactive}
  end

  @doc """
  Whether the principal's role rows grant `capability` (ignoring ownership
  and profile activity). Reads `user_roles` only, so it is safe inside a
  transaction.
  """
  @spec holds?(String.t(), capability()) :: boolean()
  def holds?(principal_id, capability) when is_binary(principal_id) do
    roles = rule!(capability).roles

    Repo.exists?(from(r in UserRole, where: r.principal_id == ^principal_id and r.role in ^roles))
  end

  @doc """
  Principal ids that hold `capability` through a role on an **active**
  profile — the same eligibility a session needs to pass `RequireSession`.
  Inactive or profile-less principals are omitted even if a leftover role row
  remains. `except:` drops one principal id; `only:` narrows the answer to
  the given principal ids.
  """
  @spec principal_ids_with(capability(), keyword()) :: [String.t()]
  def principal_ids_with(capability, opts \\ []) when is_list(opts) do
    roles = rule!(capability).roles
    except = Keyword.get(opts, :except)

    from(r in UserRole,
      join: p in UserProfile,
      on: p.principal_id == r.principal_id,
      where: r.role in ^roles,
      where: p.is_active == true,
      select: r.principal_id,
      distinct: true
    )
    |> only_principals(Keyword.get(opts, :only))
    |> Repo.all()
    |> Enum.reject(&(&1 == except))
  end

  defp only_principals(query, nil), do: query

  defp only_principals(query, ids) when is_list(ids),
    do: where(query, [r], r.principal_id in ^ids)

  defp granted_by_role?(capability, roles) do
    granted = rule!(capability).roles
    Enum.any?(roles, &(&1 in granted))
  end

  defp owner?(%{principal: %{id: id}}, %{owner_principal_id: id}) when is_binary(id), do: true
  defp owner?(_projection, _resource), do: false

  defp assigned?(%{principal: %{id: id}}, %{assigned_principal_ids: ids})
       when is_binary(id) and is_list(ids),
       do: id in ids

  defp assigned?(_projection, _resource), do: false

  defp rule!(capability) do
    case Map.fetch(@rules, capability) do
      {:ok, rule} -> rule
      :error -> raise ArgumentError, "unknown capability #{inspect(capability)}"
    end
  end
end
