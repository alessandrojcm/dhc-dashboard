defmodule DhcWeb.BeginnersWorkshopPeopleJSON do
  @moduledoc "Renders the Waitlist view's people (ALE-417), keyed by Waitlist entry id."

  def index(%{people: people}),
    do: %{data: Map.new(people, fn {id, person} -> {id, person(person)} end)}

  defp person(person) do
    %{
      carriedFee: person.carried_fee,
      availableCommands: person.available_commands,
      refundChoice: person.refund_choice && refund_choice(person.refund_choice)
    }
  end

  defp refund_choice(choice),
    do: %{source: choice.source, amountCents: choice.amount_cents, currency: choice.currency}
end
