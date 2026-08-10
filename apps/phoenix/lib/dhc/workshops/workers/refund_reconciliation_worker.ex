defmodule Dhc.Workshops.Workers.RefundReconciliationWorker do
  @moduledoc false

  use Oban.Worker, queue: :stripe, max_attempts: 5, unique: [period: 300]

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.Workshops.Refund

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    from(r in Refund,
      where: r.status == "processing" and not is_nil(r.stripe_refund_id),
      select: r.stripe_refund_id
    )
    |> Repo.all()
    |> Enum.reduce(:ok, fn stripe_refund_id, result ->
      refund_result =
        with {:ok, object} <- stripe_adapter().retrieve_refund(stripe_refund_id),
             :ok <- Refund.apply_provider_update(object) do
          :ok
        end

      case {result, refund_result} do
        {:ok, {:error, reason}} -> {:error, reason}
        _ -> result
      end
    end)
  end

  defp stripe_adapter do
    Application.fetch_env!(:dhc, :workshop_stripe_adapter)
  end
end
