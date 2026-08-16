defmodule Dhc.Workshops.Workers.RefundReconciliationWorker do
  @moduledoc false

  use Oban.Worker, queue: :stripe, max_attempts: 5, unique: [period: 300]

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.Workshops.Refund
  alias Dhc.Workshops.Workers.RefundWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    submission_results =
      from(r in Refund,
        where: r.status == "pending",
        select: r.id
      )
      |> Repo.all()
      |> Enum.map(fn refund_id ->
        refund_id
        |> then(&RefundWorker.new(%{refund_id: &1}))
        |> Oban.insert()
        |> case do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

    provider_results =
      from(r in Refund,
        where: r.status == "processing" and not is_nil(r.stripe_refund_id),
        select: r.stripe_refund_id
      )
      |> Repo.all()
      |> Enum.map(fn stripe_refund_id ->
        with {:ok, object} <- stripe_adapter().retrieve_refund(stripe_refund_id) do
          Refund.apply_provider_update(object)
        end
      end)

    Enum.find(submission_results ++ provider_results, :ok, &match?({:error, _reason}, &1))
  end

  defp stripe_adapter do
    Application.fetch_env!(:dhc, :workshop_stripe_adapter)
  end
end
