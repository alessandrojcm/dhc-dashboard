defmodule Dhc.BeginnersWorkshops.Workers.SweepWorkerTest do
  @moduledoc """
  ALE-380: wiring of the one periodic Beginners' Workshop sweep. The pass
  rules are proven in `Dhc.BeginnersWorkshops.BatchesTest`; this checks the
  worker runs the due passes through the boundary at the job's clock and
  succeeds when there is nothing to do or a pass fails.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures
  import ExUnit.CaptureLog

  alias Dhc.BeginnersWorkshops.{Batch, Workers.SweepWorker}
  alias Dhc.BeginnersWorkshops.IntakeEmails.Template
  alias Dhc.Repo

  @batch_1_at "2026-10-20T09:00:00Z"

  defp perform_job(args \\ %{"at" => @batch_1_at}),
    do: SweepWorker.perform(%Oban.Job{args: args})

  test "sends a Batch that is due, once per window" do
    workshop = scheduled_fixture(staff_fixture(), %{"contact_from" => "2026-10-20"})
    waiting_people_fixture(2)

    assert :ok = perform_job()
    assert [%Batch{size: 2}] = Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id))

    assert :ok = perform_job()
    assert Repo.aggregate(Batch, :count) == 1
  end

  test "succeeds with nothing to do, on the wall clock too" do
    assert :ok = perform_job()
    assert :ok = perform_job(%{})
  end

  test "a failed pass is logged and left to the next tick" do
    scheduled_fixture(staff_fixture(), %{"contact_from" => "2026-10-20"})
    waiting_people_fixture(1)

    Repo.update_all(Template |> where(email_type: "contact_pay"),
      set: [
        body: %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "placeholder", "attrs" => %{"name" => "refundAmount"}}]
            }
          ]
        }
      ]
    )

    assert capture_log(fn -> assert :ok = perform_job() end) =~ "1 pass(es) failed"
    assert Repo.aggregate(Batch, :count) == 0
  end
end
