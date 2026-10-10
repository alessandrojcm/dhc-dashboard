defmodule DhcWeb.BeginnersWorkshopIntakesJSON do
  @moduledoc "Renders an Intake after a console Intake command, as `DhcWeb.BeginnersWorkshopsJSON` does."

  defdelegate intake_command(assigns), to: DhcWeb.BeginnersWorkshopsJSON

  @doc "The person after a withdraw (ALE-387), and their Intake if one closed."
  def withdraw_person(%{result: result}) do
    %{
      data: %{
        waitlistId: result.waitlist_id,
        status: result.status,
        intake: result.intake && intake_command(%{result: result.intake}).data,
        outcome: result.outcome
      }
    }
  end

  @doc "A deleted person (ALE-396): how many Intakes were anonymised, and the settled Carried Fee."
  def delete_person(%{result: result}) do
    %{
      data: %{
        waitlistId: result.waitlist_id,
        anonymisedIntakes: result.anonymised_intakes,
        carriedFee: result.carried_fee && Map.take(result.carried_fee, [:id, :status])
      }
    }
  end
end
