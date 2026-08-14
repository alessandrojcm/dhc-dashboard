defmodule Dhc.Discord.RosterExecutions do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.Discord.RosterExecution
  alias Dhc.Repo

  @member_admin_roles ~w(
    admin president treasurer committee_coordinator sparring_coordinator
    workshop_coordinator beginners_coordinator quartermaster pr_manager
    volunteer_coordinator research_coordinator coach
  )

  def claim(execution_id, options) do
    Repo.transaction(fn ->
      execution =
        Repo.one(
          from execution in RosterExecution,
            where: execution.id == ^execution_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:execution_not_approved)

      authorize!(execution, options)

      execution
      |> RosterExecution.transition_changeset(%{
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()
      |> case do
        {:ok, execution} -> execution
        {:error, changeset} -> Repo.rollback({:execution_claim_failed, changeset})
      end
    end)
  end

  def complete(%RosterExecution{} = execution, outcome) when outcome in [:succeeded, :failed] do
    execution
    |> RosterExecution.transition_changeset(%{
      status: outcome,
      finished_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp authorize!(execution, options) do
    now = DateTime.utc_now()

    cond do
      execution.status != :approved ->
        Repo.rollback(:execution_not_approved)

      DateTime.compare(execution.expires_at, now) != :gt ->
        Repo.rollback(:execution_expired)

      execution.guild_id != options.guild_id or
        execution.bot_application_id != options.bot_application_id or
          execution.tool_revision != options.tool_revision ->
        Repo.rollback(:execution_configuration_mismatch)

      not authorized_actor?(execution.actor_id) ->
        Repo.rollback(:execution_actor_not_authorized)

      true ->
        :ok
    end
  end

  defp authorized_actor?(actor_id) do
    Repo.exists?(
      from role in UserRole,
        where: role.principal_id == ^actor_id and role.role in ^@member_admin_roles
    )
  end
end
