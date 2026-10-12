defmodule Dhc.BeginnersWorkshops.Commands.WorkshopRules do
  @moduledoc """
  The workshop-level reads and rules several command families judge under
  the Beginners' Workshop lock (ALE-405): the workshop's `WorkshopFacts`,
  whether it is still scheduled, and whether its Payment Cutoff has passed.

  Callers: `Commands.Schedule`, `Commands.Batches`, `Commands.Payments`,
  `Commands.IntakeCommands`, `Commands.Attendance` and `Commands.Staff`.
  Reach lets only `Commands` and `Commands.*` call this module.
  """

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, WorkshopFacts, WorkshopPolicy}

  @doc false
  # The locked workshop's facts (seats taken, Batches sent, ...).
  @spec facts_for(BeginnersWorkshop.t()) :: WorkshopFacts.t()
  def facts_for(%BeginnersWorkshop{id: id}), do: Map.fetch!(WorkshopFacts.load([id]), id)

  @doc false
  @spec still_scheduled(BeginnersWorkshop.t()) ::
          :ok | {:error, :after_finalisation | :already_cancelled}
  def still_scheduled(%BeginnersWorkshop{status: "scheduled"}), do: :ok
  def still_scheduled(%BeginnersWorkshop{status: "finalised"}), do: {:error, :after_finalisation}
  def still_scheduled(%BeginnersWorkshop{status: "cancelled"}), do: {:error, :already_cancelled}

  @doc false
  # A scheduled workshop whose Payment Cutoff has passed: the cutoff pass is
  # due, and a person paid now gets Pre-workshop info at once.
  @spec cutoff_due?(BeginnersWorkshop.t(), Clock.reading()) :: boolean()
  def cutoff_due?(workshop, reading),
    do: workshop.status == "scheduled" and not WorkshopPolicy.payment_open?(workshop, reading)
end
