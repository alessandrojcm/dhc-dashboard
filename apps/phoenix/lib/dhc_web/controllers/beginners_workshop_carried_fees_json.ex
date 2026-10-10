defmodule DhcWeb.BeginnersWorkshopCarriedFeesJSON do
  @moduledoc "Renders the Waitlist view's Carried Fee statuses, keyed by Waitlist entry id."

  def index(%{carried_fees: carried_fees}), do: %{data: carried_fees}
end
