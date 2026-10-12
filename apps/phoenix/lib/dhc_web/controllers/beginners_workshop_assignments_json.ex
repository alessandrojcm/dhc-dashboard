defmodule DhcWeb.BeginnersWorkshopAssignmentsJSON do
  @moduledoc "Renders `Dhc.BeginnersWorkshops.MyWorkshops` rows."

  alias DhcWeb.BeginnersWorkshopsJSON

  def list(%{rows: rows}) do
    %{
      data:
        Enum.map(rows, fn row ->
          %{
            id: row.id,
            status: row.status,
            venue: row.venue,
            date: row.date,
            startTime: BeginnersWorkshopsJSON.hh_mm(row.start_time),
            stage: row.stage,
            role: row.role
          }
        end)
    }
  end
end
