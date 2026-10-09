defmodule DhcWeb.BeginnersWorkshopBatchesJSON do
  @moduledoc "Renders the workshop after a pause or resume, as `DhcWeb.BeginnersWorkshopsJSON` does."

  defdelegate show(assigns), to: DhcWeb.BeginnersWorkshopsJSON
end
