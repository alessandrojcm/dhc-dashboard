defmodule Dhc.DiscordAssignmentFixtures do
  @moduledoc false

  @fingerprint_key "discord-assignment-fixture-fingerprint-key"

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    RosterExecution,
    RosterReceipts,
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
    revision = "ale-218-test"

    execution =
      %RosterExecution{actor_id: preparer}
      |> RosterExecution.approval_changeset(%{
        guild_id: "ale-218-guild",
        bot_application_id: "ale-218-bot",
        tool_revision: revision,
        status: :approved,
        approved_at: now,
        expires_at: DateTime.add(now, 3_600, :second)
      })
      |> Repo.insert!()

    {:ok, preflight} =
      RosterReceipts.create(%{
        execution_id: execution.id,
        kind: :preflight,
        status: :succeeded,
        actor_id: preparer,
        guild_id: "ale-218-guild",
        bot_application_id: "ale-218-bot",
        tool_revision: revision,
        evidence_digest: digest("preflight"),
        record_count: 1,
        result: "preflight succeeded"
      })

    {:ok, capture} =
      RosterReceipts.create(%{
        execution_id: execution.id,
        kind: :capture,
        status: :succeeded,
        actor_id: preparer,
        guild_id: "ale-218-guild",
        bot_application_id: "ale-218-bot",
        tool_revision: revision,
        evidence_digest: digest("capture"),
        package_digest: digest(subject),
        record_count: 1,
        result: "capture succeeded",
        preflight_receipt_id: preflight.id
      })

    stage_execution =
      %AssignmentStageExecution{}
      |> AssignmentStageExecution.changeset(%{
        capture_id: capture.id,
        manifest_digest: digest("stage-#{subject}"),
        preparer_principal_id: preparer,
        tool_revision: revision,
        executed_at: now
      })
      |> Repo.insert!()

    assignment =
      %StagedAssignment{}
      |> StagedAssignment.proposal_changeset(%{
        principal_id: target_principal_id,
        capture_id: capture.id,
        stage_execution_id: stage_execution.id,
        provider: "discord",
        provider_subject: subject,
        username_snapshot: Map.get(attrs, :username_snapshot, "reviewed-user"),
        subject_fingerprint: Dhc.Discord.SubjectFingerprint.generate(subject, @fingerprint_key),
        proposal_digest: digest("proposal:#{subject}"),
        state: "proposed",
        prepared_by_principal_id: preparer,
        tool_revision: revision
      })
      |> Repo.insert!()

    review_execution =
      if state in ["approved", "rejected"] do
        %AssignmentReviewExecution{}
        |> AssignmentReviewExecution.changeset(%{
          capture_id: capture.id,
          manifest_digest: digest("review-#{subject}"),
          reviewer_principal_id: reviewer,
          tool_revision: revision,
          executed_at: now,
          state: "applied"
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
      email: "ale-218-#{label}-#{System.unique_integer([:positive])}@example.com"
    })

    id
  end

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
