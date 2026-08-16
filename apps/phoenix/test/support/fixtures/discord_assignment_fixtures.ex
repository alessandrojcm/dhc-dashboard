defmodule Dhc.DiscordAssignmentFixtures do
  @moduledoc false

  @fingerprint_key "discord-assignment-fixture-fingerprint-key"

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    StagedAssignment
  }

  alias Dhc.Repo

  def approved_assignment_fixture(target_principal_id, subject, attrs \\ %{}) do
    assignment_fixture(
      target_principal_id,
      subject,
      Map.put(Enum.into(attrs, %{}), :state, "approved")
    )
  end

  def assignment_fixture(target_principal_id, subject, attrs \\ %{}) do
    {:ok, assignment} =
      Repo.transaction(fn ->
        create_assignment_fixture(target_principal_id, subject, attrs)
      end)

    assignment
  end

  defp create_assignment_fixture(target_principal_id, subject, attrs) do
    attrs = Enum.into(attrs, %{})
    state = Map.get(attrs, :state, "proposed")
    preparer = member_fixture("preparer")
    reviewer = member_fixture("reviewer")
    now = DateTime.utc_now()
    revision = "discord-assignment-test"
    capture_id = Ecto.UUID.generate()

    stage_execution =
      %AssignmentStageExecution{}
      |> AssignmentStageExecution.changeset(%{
        capture_id: capture_id,
        preparer_principal_id: preparer,
        tool_revision: revision,
        executed_at: now
      })
      |> Repo.insert!()

    assignment =
      %StagedAssignment{}
      |> StagedAssignment.proposal_changeset(%{
        principal_id: target_principal_id,
        capture_id: capture_id,
        stage_execution_id: stage_execution.id,
        provider: "discord",
        provider_subject: subject,
        username_snapshot: Map.get(attrs, :username_snapshot, "reviewed-user"),
        subject_fingerprint: Dhc.Discord.SubjectFingerprint.generate(subject, @fingerprint_key),
        state: "proposed",
        prepared_by_principal_id: preparer,
        tool_revision: revision
      })
      |> Repo.insert!()

    review_execution =
      if state in ["approved", "rejected"] do
        %AssignmentReviewExecution{}
        |> AssignmentReviewExecution.changeset(%{
          capture_id: capture_id,
          reviewer_principal_id: reviewer,
          tool_revision: revision,
          executed_at: now
        })
        |> Repo.insert!()
      end

    case state do
      "proposed" ->
        assignment

      "approved" ->
        assignment
        |> StagedAssignment.transition_changeset(%{
          state: "approved",
          approved_by_principal_id: reviewer,
          review_execution_id: review_execution.id,
          approved_at: now
        })
        |> Repo.update!()

      "rejected" ->
        assignment
        |> StagedAssignment.transition_changeset(%{
          state: "rejected",
          review_execution_id: review_execution.id,
          terminal_at: now,
          terminal_actor_principal_id: reviewer,
          reason_code: "review_rejected"
        })
        |> Repo.update!()
    end
  end

  def fingerprint_key, do: @fingerprint_key

  defp member_fixture(label) do
    id = Ecto.UUID.generate()

    Dhc.MemberFixtures.member_fixture(%{
      principal_id: id,
      email: "discord-assignment-#{label}-#{System.unique_integer([:positive])}@example.com"
    })

    id
  end
end
