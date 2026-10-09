defmodule DhcWeb.BeginnersWorkshopIntakesJSON do
  @moduledoc "Renders an Intake after a console Intake command, as `DhcWeb.BeginnersWorkshopsJSON` does."

  defdelegate intake_command(assigns), to: DhcWeb.BeginnersWorkshopsJSON
end
