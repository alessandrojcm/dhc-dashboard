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

  @beginners_staff @officers ++ ~w(coach beginners_coordinator)

  # ALE-330: no read/manage split — only the committee shapes club
  # communications.
  @training_announcement_managers ~w(sparring_coordinator coach president admin committee_coordinator)

  # Every authenticated user carries the `member` role.
  @members ~w(member)

  # ── Registry ──────────────────────────────────────────────────────────

  @rules %{
    "beginners.workshop.read": %{roles: @beginners_staff},
    # Opening or closing the waitlist (`PATCH /waitlist/status`) is an
    # officer decision; the rest of the beginners staff only read and work
    # the list.
    "beginners.waitlist.toggle": %{roles: @officers},
    "discord.assignments.manage": %{roles: @member_administrators},
    "discord.doctor.use": %{roles: @officers},
    "inventory.manage": %{roles: @inventory_operators},
    "inventory.catalog.read": %{roles: @members},
    "inventory.loans.own.read": %{roles: @members},
    # ADR 0028: emailing the whole membership is an officer decision.
    "member_announcements.send": %{roles: @officers},
    "members.directory.read": %{roles: @member_administrators},
    "members.invite": %{roles: @officers},
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
  @type resource :: %{optional(:owner_principal_id) => String.t() | nil}

  @doc "Every capability in the registry, sorted."
  @spec all() :: [capability()]
  def all, do: @capabilities

  @doc "Whether `capability` is in the registry."
  @spec exists?(term()) :: boolean()
  def exists?(capability), do: Map.has_key?(@rules, capability)

  @doc "Whether the capability is also granted to the resource owner."
  @spec owner_scoped?(capability()) :: boolean()
  def owner_scoped?(capability), do: Map.get(rule!(capability), :owner, false)

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
  `{:error, :not_found}` (owner-scoped capability denied — HTTP 404, the
  resource is concealed) or `{:error, :forbidden}` (HTTP 403).
  """
  @spec authorize(map(), capability() | nil, resource()) ::
          :ok | {:error, :inactive | :forbidden | :not_found}
  def authorize(projection, capability, resource \\ %{})

  def authorize(%{is_active: true}, nil, _resource), do: :ok

  def authorize(%{is_active: true, roles: roles} = projection, capability, resource) do
    cond do
      granted_by_role?(capability, roles) -> :ok
      not owner_scoped?(capability) -> {:error, :forbidden}
      owner?(projection, resource) -> :ok
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
  remains. `except:` drops one principal id.
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
    |> Repo.all()
    |> Enum.reject(&(&1 == except))
  end

  defp granted_by_role?(capability, roles) do
    granted = rule!(capability).roles
    Enum.any?(roles, &(&1 in granted))
  end

  defp owner?(%{principal: %{id: id}}, %{owner_principal_id: id}) when is_binary(id), do: true
  defp owner?(_projection, _resource), do: false

  defp rule!(capability) do
    case Map.fetch(@rules, capability) do
      {:ok, rule} -> rule
      :error -> raise ArgumentError, "unknown capability #{inspect(capability)}"
    end
  end
end
