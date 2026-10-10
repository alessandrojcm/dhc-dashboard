defmodule DhcWeb.BeginnersWorkshopRefundsJSON do
  @moduledoc "Renders a refund after Retry or Record manual refund, as `DhcWeb.BeginnersWorkshopsJSON` does."

  defdelegate refund(assigns), to: DhcWeb.BeginnersWorkshopsJSON
  defdelegate forfeited(assigns), to: DhcWeb.BeginnersWorkshopsJSON
end
