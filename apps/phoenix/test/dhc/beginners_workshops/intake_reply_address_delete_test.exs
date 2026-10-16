defmodule Dhc.BeginnersWorkshops.IntakeReplyAddressDeleteTest do
  @moduledoc "ALE-407: hard deletion and retention purge revoke reply addresses."

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions
  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, IntakeEmails, IntakeReplies}
  alias Dhc.BeginnersWorkshops.IntakeEmails.Occasion
  alias Dhc.Email.Worker
  alias Dhc.Repo

  @now ~U[2026-10-23 12:00:00.000000Z]

  setup do
    original_domain = Application.get_env(:dhc, :intake_reply_domain)
    Application.put_env(:dhc, :intake_reply_domain, "reply.example.test")

    on_exit(fn ->
      if is_nil(original_domain) do
        Application.delete_env(:dhc, :intake_reply_domain)
      else
        Application.put_env(:dhc, :intake_reply_domain, original_domain)
      end
    end)

    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp issue_reply_address(person) do
    assert {:ok, :queued} =
             IntakeEmails.deliver(
               {:person, person, nil},
               "withdrawn_forfeited",
               Occasion.withdrawn(Ecto.UUID.generate()),
               Clock.read(Clock.fixed(@now))
             )

    assert [%{args: args}] = all_enqueued(worker: Worker)
    assert is_binary(args["sealed_reply_to"])
    assert :ok = Worker.perform(%Oban.Job{id: 808, args: args})

    assert_email_sent(fn email ->
      send(self(), {:reply_to, email.reply_to})
      true
    end)

    assert_receive {:reply_to, {"", address}}
    address
  end

  test "delete_person removes all reply addresses in its command transaction", %{coordinator: c} do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    address = issue_reply_address(person)
    assert {:ok, _binding} = IntakeReplies.resolve(address)

    assert {:ok, %{outcome: :deleted}} =
             BeginnersWorkshops.execute({:staff, c}, {:delete_person, person.id, %{}})

    assert :unknown = IntakeReplies.resolve(address)
  end

  test "purge_retention removes all reply addresses in its command transaction" do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

    person =
      person
      |> Ecto.Changeset.change(status: "removed", removed_at: ~U[2026-07-22 12:00:00Z])
      |> Repo.update!()

    address = issue_reply_address(person)
    assert {:ok, _binding} = IntakeReplies.resolve(address)

    assert {:ok, %{outcome: :purged}} =
             BeginnersWorkshops.execute(:system, {:purge_retention, person.id},
               clock: Clock.fixed(@now)
             )

    assert :unknown = IntakeReplies.resolve(address)
  end
end
