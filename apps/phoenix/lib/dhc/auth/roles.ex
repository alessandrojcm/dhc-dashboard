defmodule Dhc.Auth.Roles do
  @moduledoc """
  Member role editing and atomic session/socket revocation.

  Edits serialize on one advisory lock, then actor/target access rows in id
  order (the same rows sign-in locks). Expected roles prevent stale editors
  overwriting each other. The last active role editor cannot remove their
  authority. Socket disconnect happens only after commit, never on a no-op.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, PrincipalToken, UserRole}
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach member)

  def available, do: @roles

  def show(actor_id, member_id) do
    with :ok <- authorize(actor_id),
         {:ok, id} <- member_id(member_id) do
      {:ok, view(id)}
    end
  end

  def update(actor_id, member_id, payload) do
    with :ok <- authorize(actor_id),
         {:ok, id} <- member_id(member_id),
         {:ok, desired, expected} <- validate(payload) do
      update_locked(actor_id, id, desired, expected)
    end
  end

  defp update_locked(actor_id, id, desired, expected) do
    if Repo.in_transaction?(), do: raise(ArgumentError, "role edits must own their transaction")

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('dhc:member-role-editor', 0))")

      from(p in UserProfile,
        where: p.principal_id in ^Enum.uniq([actor_id, id]),
        order_by: p.id,
        lock: "FOR UPDATE"
      )
      |> Repo.all()

      apply_edit!(actor_id, id, desired, expected)
    end)
    |> case do
      {:ok, {view, true}} ->
        Auth.disconnect_sockets(id)
        {:ok, view}

      {:ok, {view, false}} ->
        {:ok, view}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_edit!(actor_id, id, desired, expected) do
    with :ok <- authorize(actor_id),
         {:ok, _} <- member_id(id) do
      current = roles(id)
      if current != expected, do: Repo.rollback(:roles_changed)
      changed = current != desired
      if changed, do: replace_roles!(id, desired)
      {view(id), changed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp replace_roles!(id, desired) do
    Repo.delete_all(from(r in UserRole, where: r.principal_id == ^id))
    Repo.insert_all(UserRole, Enum.map(desired, &%{principal_id: id, role: &1}))

    if Capabilities.principal_ids_with(:"members.roles.edit") == [],
      do: Repo.rollback(:last_role_editor)

    Repo.delete_all(
      from(t in PrincipalToken,
        where: t.principal_id == ^id and t.context in ["session", "socket"]
      )
    )
  end

  defp authorize(actor_id) do
    case Repo.get(Dhc.Auth.Principal, actor_id) do
      nil ->
        {:error, :forbidden}

      principal ->
        with {:ok, projection} <- Auth.load_session_principal(principal),
             :ok <- Capabilities.authorize(projection, :"members.roles.edit") do
          :ok
        else
          _ -> {:error, :forbidden}
        end
    end
  end

  defp member_id(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- Repo.exists?(from(m in MemberProfile, where: m.id == ^id)) do
      {:ok, id}
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate(%{"roles" => desired, "expectedRoles" => expected} = payload) do
    if map_size(payload) == 2 and valid_roles?(desired) and valid_roles?(expected) do
      {:ok, Enum.sort(desired), Enum.sort(expected)}
    else
      {:error, :invalid_roles}
    end
  end

  defp validate(_), do: {:error, :invalid_roles}

  defp valid_roles?(roles) when is_list(roles),
    do:
      length(roles) <= length(@roles) and Enum.uniq(roles) == roles and
        Enum.all?(roles, &(&1 in @roles))

  defp valid_roles?(_), do: false

  defp roles(id),
    do:
      Repo.all(from(r in UserRole, where: r.principal_id == ^id, select: r.role))
      |> Enum.sort()

  defp view(id), do: %{roles: roles(id), availableRoles: available()}
end
