defmodule Dhc.BeginnersWorkshops.Commands.CoordinatorAlerts do
  @moduledoc """
  Keyed Notifications to the coordinator-alert recipients (ALE-380): every
  holder of `beginners.workshops.alerts.receive`, inserted in the command's
  transaction and signalled by the caller after commit (ALE-405).

  Callers: `Commands.Batches` ("Batch sent", "nobody waiting") and
  `Commands.Refunds` (a failed refund); their text comes from
  `Commands.NotificationCopy`. Reach lets only `Commands` and `Commands.*`
  call this module.
  """

  import Dhc.BeginnersWorkshops.Commands.Protocol, only: [create_keyed: 1]

  alias Dhc.Auth.Capabilities

  # The coordinator-alert recipients (ALE-380).
  @alerts_capability :"beginners.workshops.alerts.receive"

  @doc false
  @spec alert(String.t(), String.t()) :: {:ok, list()} | {:error, term()}
  def alert(key, body) do
    @alerts_capability
    |> Capabilities.principal_ids_with()
    |> Enum.map(&{&1, key, body})
    |> create_keyed()
  end
end
