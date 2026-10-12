defmodule Dhc.BeginnersWorkshops.Commands.IntakeNotices do
  @moduledoc """
  The Intake Emails several command families queue the same way, through
  `IntakeEmails.deliver/5` inside the command's transaction (ALE-401,
  ALE-405), and the adapter that lets a `with` go on after a delivery.

    * `emailed/1`, `emailed_each/2` — every family that queues an Intake
      Email (`Commands.Schedule`, `Commands.Batches`, `Commands.Payments`,
      `Commands.Refunds`, `Commands.IntakeCommands`);
    * `place_confirmed/3` — `Commands.Payments` (a Stripe payment) and
      `Commands.IntakeCommands` (`confirm` with a Carried Fee);
    * `pre_workshop/3` — `place_confirmed/3` and `Commands.Attendance`
      (the Payment Cutoff pass).

  Reach lets only `Commands` and `Commands.*` call this module.
  """

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules, only: [cutoff_due?: 2]

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, Intake, IntakeEmails}
  alias Dhc.BeginnersWorkshops.IntakeEmails.Occasion

  @doc false
  # "Place confirmed" for a newly paid or confirmed Intake. A person paid
  # after the Payment Cutoff of a scheduled workshop gets Pre-workshop info
  # at once (story 49); before it, the cutoff pass sends it, and a cancelled
  # or finalised workshop sends none.
  @spec place_confirmed(Intake.t(), BeginnersWorkshop.t(), Clock.reading()) ::
          :ok | {:error, term()}
  def place_confirmed(intake, workshop, reading) do
    with :ok <-
           emailed(
             IntakeEmails.deliver(
               {:intake, intake, workshop},
               :place_confirmed,
               Occasion.place_confirmed(),
               reading
             )
           ) do
      if cutoff_due?(workshop, reading),
        do: emailed(pre_workshop(intake, workshop, reading)),
        else: :ok
    end
  end

  @doc false
  # "Pre-workshop info", once per Intake per schedule (ALE-394).
  @spec pre_workshop(Intake.t(), BeginnersWorkshop.t(), Clock.reading()) ::
          {:ok, :queued | :already_sent | :no_recipient} | {:error, term()}
  def pre_workshop(intake, workshop, reading) do
    IntakeEmails.deliver(
      {:intake, intake, workshop},
      "pre_workshop",
      Occasion.pre_workshop(workshop.reschedule_count),
      reading
    )
  end

  @doc false
  # `IntakeEmails.deliver/5` in a `with`: queued, already sent and nobody
  # to send to all go on.
  @spec emailed({:ok, term()} | {:error, term()}) :: :ok | {:error, term()}
  def emailed({:ok, _queued_or_not}), do: :ok
  def emailed({:error, reason}), do: {:error, reason}

  @doc false
  @spec emailed_each(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          :ok | {:error, term()}
  def emailed_each(items, deliver) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case emailed(deliver.(item)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
