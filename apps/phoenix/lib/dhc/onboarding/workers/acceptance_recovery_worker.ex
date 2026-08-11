defmodule Dhc.Onboarding.Workers.AcceptanceRecoveryWorker do
  @moduledoc false

  use Oban.Worker, queue: :invitations, max_attempts: 10

  import Ecto.Query

  alias Dhc.Invitations
  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id}}) do
    query =
      from(a in InvitationAcceptanceAttempt,
        join: i in Invitation,
        on: i.id == a.invitation_id,
        where: a.id == ^attempt_id,
        select: {a, i}
      )

    case Repo.one(query) do
      {%InvitationAcceptanceAttempt{status: "provisioned"} = attempt,
       %Invitation{status: "pending"} = invitation} ->
        Invitations.convert(
          invitation.id,
          attempt.id,
          attempt.acceptance_data["next_of_kin_name"],
          attempt.acceptance_data["next_of_kin_phone"],
          attempt.stripe_customer_id
        )
        |> case do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {%InvitationAcceptanceAttempt{status: "completed"}, _invitation} ->
        :ok

      nil ->
        :discard

      {_attempt, _invitation} ->
        {:snooze, 60}
    end
  end
end
