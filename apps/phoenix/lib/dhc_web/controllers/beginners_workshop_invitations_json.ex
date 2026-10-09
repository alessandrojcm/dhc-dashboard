defmodule DhcWeb.BeginnersWorkshopInvitationsJSON do
  @moduledoc "Renders the Invitable view and an Invitation handoff (ALE-392)."

  def invitable(%{result: rows}), do: %{data: Enum.map(rows, &invitable_row/1)}

  def invite(%{result: invited}) do
    %{
      data: %{
        intakeId: invited.intake_id,
        workshopId: invited.workshop_id,
        waitlistId: invited.waitlist_id,
        invitationId: invited.invitation_id,
        standing: invited.standing
      }
    }
  end

  defp invitable_row(row) do
    %{
      intakeId: row.intake_id,
      workshopId: row.workshop_id,
      workshopDate: row.workshop_date,
      waitlistId: row.waitlist_id,
      firstName: row.first_name,
      lastName: row.last_name,
      email: row.email,
      followUp: %{status: row.follow_up.status, at: row.follow_up.at}
    }
  end
end
