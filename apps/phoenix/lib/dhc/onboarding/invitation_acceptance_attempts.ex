defmodule Dhc.Onboarding.InvitationAcceptanceAttempts do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo

  @spec purge_for_invitation(Ecto.UUID.t()) :: non_neg_integer()
  def purge_for_invitation(invitation_id) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from(c in InvitationAcceptanceDiscordContinuation,
          where: c.invitation_id == ^invitation_id
        )
      )

      {count, _rows} =
        Repo.delete_all(
          from(a in InvitationAcceptanceAttempt, where: a.invitation_id == ^invitation_id)
        )

      count
    end)
    |> then(fn {:ok, count} -> count end)
  end
end
