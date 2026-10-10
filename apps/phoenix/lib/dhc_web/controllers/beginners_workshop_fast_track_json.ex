defmodule DhcWeb.BeginnersWorkshopFastTrackJSON do
  @moduledoc "Renders the Fast-track search and a fast-tracked Intake (ALE-384)."

  def candidates(%{result: candidates}), do: %{data: Enum.map(candidates, &candidate/1)}

  def show(%{result: intake}) do
    %{
      data: %{
        intakeId: intake.id,
        workshopId: intake.workshop_id,
        waitlistId: intake.waitlist_id,
        state: intake.state,
        origin: intake.origin,
        contactedAt: intake.contacted_at,
        placed: intake.placed
      }
    }
  end

  defp candidate(row) do
    %{
      waitlistId: row.waitlist_id,
      firstName: row.first_name,
      lastName: row.last_name,
      email: row.email,
      status: row.status,
      removedAt: row.removed_at,
      minor: row.minor
    }
  end
end
