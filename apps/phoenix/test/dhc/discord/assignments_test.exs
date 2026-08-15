defmodule Dhc.Discord.AssignmentsTest do
  use Dhc.DataCase, async: false

  import ExUnit.CaptureIO

  alias Dhc.Auth.ExternalIdentity

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    AssignmentStageResult,
    Assignments,
    StagedAssignment,
    StagedAssignmentAuditEvent
  }

  alias Dhc.Repo

  setup do
    preparer = member_fixture("preparer", "admin")
    reviewer = member_fixture("reviewer", "president")
    target = member_fixture("target")
    subject = unique_subject()

    roster = [
      %{
        "id" => subject,
        "username" => "target-user",
        "global_name" => "Target",
        "nickname" => "Club Target"
      }
    ]

    %{
      preparer: preparer,
      reviewer: reviewer,
      target: target,
      subject: subject,
      roster: roster,
      options: %{
        fingerprint_key: "fingerprint-test-key",
        tool_revision: "plain-json-test"
      }
    }
  end

  test "stages only validated rows from the plain roster and appends a safe audit event",
       context do
    assert {:ok, result} =
             Assignments.stage(
               context.roster,
               stage_rows(context),
               context.preparer.id,
               context.options
             )

    assert result.counts == %{"proposed" => 1}
    assert {:ok, _capture_id} = Ecto.UUID.cast(result.capture_id)
    [row] = result.rows
    assert row.principal_id == context.target.id
    refute inspect(result) =~ context.subject
    refute inspect(result) =~ "target-user"

    assignment = Repo.get!(StagedAssignment, row.assignment_id)
    assert assignment.capture_id == result.capture_id
    assert assignment.provider_subject == context.subject
    assert assignment.username_snapshot == "target-user"

    event =
      Repo.one!(from(e in StagedAssignmentAuditEvent, where: e.assignment_id == ^assignment.id))

    assert event.action == "proposed"
    assert event.actor_principal_id == context.preparer.id
    assert event.capture_id == result.capture_id
    refute inspect(event) =~ context.subject

    wrong_snapshot = [
      %{
        "principal_id" => context.target.id,
        "discord_user_id" => context.subject,
        "username_snapshot" => "wrong-name"
      }
    ]

    assert {:error, :row_not_in_roster} =
             Assignments.stage(
               context.roster,
               wrong_snapshot,
               context.preparer.id,
               context.options
             )
  end

  test "rejects malformed or duplicate roster members and malformed stage rows", context do
    malformed_roster = [%{"id" => context.subject, "username" => "target-user"}]

    assert {:error, :invalid_roster} =
             Assignments.stage(
               malformed_roster,
               stage_rows(context),
               context.preparer.id,
               context.options
             )

    duplicate_roster = context.roster ++ context.roster

    assert {:error, :duplicate_roster_member} =
             Assignments.stage(
               duplicate_roster,
               stage_rows(context),
               context.preparer.id,
               context.options
             )

    assert {:error, :invalid_stage_rows} =
             Assignments.stage(
               context.roster,
               ["not-a-row"],
               context.preparer.id,
               context.options
             )

    unknown_rows =
      put_in(stage_rows(context), [Access.at(0), "principal_id"], Ecto.UUID.generate())

    assert {:error, :unknown_principal} =
             Assignments.stage(
               context.roster,
               unknown_rows,
               context.preparer.id,
               context.options
             )
  end

  test "requires authorized actor IDs and a reviewer distinct from the preparer", context do
    unauthorized = member_fixture("unauthorized")

    assert {:error, :unauthorized_principal} =
             Assignments.stage(
               context.roster,
               stage_rows(context),
               unauthorized.id,
               context.options
             )

    {assignment, capture_id} = stage!(context)

    assert {:error, :reviewer_must_differ_from_preparer} =
             Assignments.review_evidence(capture_id, context.roster, context.preparer.id)

    assert {:error, :stale_or_unreviewable_proposal} =
             Assignments.apply_review(
               capture_id,
               review_rows(assignment, "approve"),
               context.preparer.id,
               context.options
             )

    assert Repo.aggregate(
             from(e in AssignmentReviewExecution, where: e.capture_id == ^capture_id),
             :count
           ) == 0
  end

  test "independent review exposes the selected roster evidence and approves or rejects explicitly",
       context do
    {assignment, capture_id} = stage!(context)

    assert {:ok, [evidence]} =
             Assignments.review_evidence(capture_id, context.roster, context.reviewer.id)

    assert evidence == %{
             assignment_id: assignment.id,
             principal_id: context.target.id,
             discord_user_id: context.subject,
             username_snapshot: "target-user",
             global_name: "Target",
             nickname: "Club Target",
             capture_id: capture_id
           }

    assert {:ok, result} =
             Assignments.apply_review(
               capture_id,
               review_rows(assignment, "approve"),
               context.reviewer.id,
               context.options
             )

    assert result.counts == %{"approved" => 1}
    refute inspect(result) =~ context.subject
    assert Repo.get!(StagedAssignment, assignment.id).state == "approved"

    assert Repo.aggregate(
             from(e in StagedAssignmentAuditEvent, where: e.assignment_id == ^assignment.id),
             :count
           ) == 2

    assert {:error, :stale_or_unreviewable_proposal} =
             Assignments.apply_review(
               capture_id,
               review_rows(assignment, "reject"),
               context.reviewer.id,
               context.options
             )
  end

  test "review fails closed when the roster no longer contains the proposed subject", context do
    {_assignment, capture_id} = stage!(context)

    assert {:error, :assignment_not_in_roster} =
             Assignments.review_evidence(capture_id, [], context.reviewer.id)

    changed_username_roster =
      update_in(context.roster, [Access.at(0), "username"], fn _ -> "different-user" end)

    assert {:error, :assignment_roster_mismatch} =
             Assignments.review_evidence(
               capture_id,
               changed_username_roster,
               context.reviewer.id
             )
  end

  test "role revocation trigger shares the assignment actor lock namespace" do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_functiondef('ale217_lock_admin_role_mutation()'::regprocedure)")

    assert definition =~ "discord/principal/"
    refute definition =~ "discord:principal:"
  end

  test "withdrawal and supersession preserve old evidence and require fresh independent review",
       context do
    {old, _capture_id} = stage!(context)

    replacement_subject = unique_subject()

    replacement_roster = [
      %{
        "id" => replacement_subject,
        "username" => "replacement-user",
        "global_name" => nil,
        "nickname" => nil
      }
    ]

    replacement_row = %{
      "principal_id" => context.target.id,
      "discord_user_id" => replacement_subject,
      "username_snapshot" => "replacement-user"
    }

    assert {:ok, result} =
             Assignments.supersede(
               old.id,
               replacement_roster,
               replacement_row,
               context.reviewer.id,
               context.options
             )

    old_after = Repo.get!(StagedAssignment, old.id)
    replacement = Repo.get!(StagedAssignment, result.replacement.assignment_id)

    assert old_after.state == "superseded"
    assert old_after.provider_subject == context.subject
    assert replacement.state == "proposed"
    assert replacement.provider_subject == replacement_subject
    assert replacement.prepared_by_principal_id == context.reviewer.id
    assert replacement.capture_id == result.capture_id

    assert {:error, :stale_or_unreviewable_proposal} =
             Assignments.apply_review(
               result.capture_id,
               review_rows(replacement, "approve"),
               context.reviewer.id,
               context.options
             )

    assert {:ok, %{counts: %{"approved" => 1}}} =
             Assignments.apply_review(
               result.capture_id,
               review_rows(replacement, "approve"),
               context.preparer.id,
               context.options
             )

    assert {:ok, %{state: "withdrawn"}} =
             Assignments.withdraw(
               replacement.id,
               context.preparer.id,
               "operator_withdrawal"
             )

    assert Repo.get!(StagedAssignment, replacement.id).state == "withdrawn"
  end

  test "report counts captured, conflicted, and omitted roster rows without leaking subjects",
       context do
    conflicted_target = member_fixture("conflicted-target")
    conflicted_subject = unique_subject()
    omitted_subject = unique_subject()

    Repo.insert!(%ExternalIdentity{
      principal_id: conflicted_target.id,
      provider: "discord",
      provider_subject: unique_subject(),
      metadata: %{}
    })

    roster = [
      hd(context.roster),
      %{
        "id" => conflicted_subject,
        "username" => "conflicted-user",
        "global_name" => nil,
        "nickname" => nil
      },
      %{
        "id" => omitted_subject,
        "username" => "omitted-user",
        "global_name" => nil,
        "nickname" => nil
      }
    ]

    rows =
      stage_rows(context) ++
        [
          %{
            "principal_id" => conflicted_target.id,
            "discord_user_id" => conflicted_subject,
            "username_snapshot" => "conflicted-user"
          }
        ]

    assert {:ok, staged} =
             Assignments.stage(roster, rows, context.preparer.id, context.options)

    assert staged.counts == %{"conflicted" => 1, "proposed" => 1}

    assignment =
      Repo.one!(
        from(a in StagedAssignment,
          where: a.capture_id == ^staged.capture_id and a.state == "proposed"
        )
      )

    assert {:ok, _} =
             Assignments.apply_review(
               staged.capture_id,
               review_rows(assignment, "approve"),
               context.reviewer.id,
               context.options
             )

    assert {:ok, report} = Assignments.report(staged.capture_id, roster, context.options)

    assert report.counts == %{
             "approved" => 1,
             "captured" => 3,
             "conflicted" => 1,
             "omitted" => 1,
             "promoted" => 0,
             "proposed" => 1,
             "rejected" => 0,
             "unresolved" => 0
           }

    assert report.rows |> Enum.map(& &1.outcome) |> Enum.sort() ==
             ["approved", "conflicted", "omitted"]

    refute inspect(report) =~ context.subject
    refute inspect(report) =~ conflicted_subject
    refute inspect(report) =~ omitted_subject
  end

  test "database keeps assignment identity, execution evidence, and audit events immutable",
       context do
    {assignment, capture_id} = stage!(context)

    assert {:ok, _} =
             Assignments.apply_review(
               capture_id,
               review_rows(assignment, "approve"),
               context.reviewer.id,
               context.options
             )

    assignment = Repo.get!(StagedAssignment, assignment.id)
    stage_execution = Repo.get!(AssignmentStageExecution, assignment.stage_execution_id)
    stage_result = Repo.get_by!(AssignmentStageResult, assignment_id: assignment.id)
    review_execution = Repo.get!(AssignmentReviewExecution, assignment.review_execution_id)

    audit =
      Repo.one!(
        from(e in StagedAssignmentAuditEvent,
          where: e.assignment_id == ^assignment.id and is_nil(e.old_state)
        )
      )

    identity_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn ->
            assignment
            |> Ecto.Changeset.change(provider_subject: "changed-subject")
            |> Repo.update!()
          end,
          mode: :savepoint
        )
      end

    assert identity_error.constraint == "staged_discord_assignments_identity_immutable"

    Enum.each(
      [stage_execution, stage_result, review_execution],
      fn record ->
        error =
          assert_raise Ecto.ConstraintError, fn ->
            Repo.transaction(fn -> Repo.delete!(record) end, mode: :savepoint)
          end

        assert error.constraint =~ "_immutable"
      end
    )

    audit_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> Repo.delete!(audit) end, mode: :savepoint)
      end

    assert audit_error.constraint == "staged_discord_assignment_audit_events_immutable"
  end

  test "database rejects a permanent Discord link overlapping an active assignment", context do
    {_assignment, _capture_id} = stage!(context)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            Repo.insert!(%ExternalIdentity{
              principal_id: context.target.id,
              provider: "discord",
              provider_subject: context.subject,
              metadata: %{}
            })

            Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.constraint in [
             "external_identities_active_assignment_conflict",
             "staged_discord_assignments_external_identity_conflict"
           ]
  end

  test "operator task consumes plain JSON files and actor IDs", context do
    directory =
      Path.join(
        System.tmp_dir!(),
        "plain-discord-assignments-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    roster_path = write_json!(directory, "roster.json", context.roster)
    stage_path = write_json!(directory, "stage.json", stage_rows(context))

    previous_fingerprint_key = System.get_env("DISCORD_SUBJECT_FINGERPRINT_KEY")
    System.put_env("DISCORD_SUBJECT_FINGERPRINT_KEY", context.options.fingerprint_key)

    on_exit(fn ->
      if previous_fingerprint_key,
        do: System.put_env("DISCORD_SUBJECT_FINGERPRINT_KEY", previous_fingerprint_key),
        else: System.delete_env("DISCORD_SUBJECT_FINGERPRINT_KEY")
    end)

    stage_output =
      run_assignments_task([
        "stage",
        roster_path,
        stage_path,
        context.preparer.id
      ])

    refute stage_output =~ context.subject
    refute stage_output =~ "target-user"

    assignment =
      Repo.one!(from(a in StagedAssignment, where: a.principal_id == ^context.target.id))

    review_output =
      run_assignments_task([
        "review",
        assignment.capture_id,
        roster_path,
        context.reviewer.id
      ])

    assert review_output =~ context.subject
    assert review_output =~ "target-user"

    review_path =
      write_json!(directory, "review.json", review_rows(assignment, "approve"))

    apply_output =
      run_assignments_task([
        "apply-review",
        assignment.capture_id,
        review_path,
        context.reviewer.id
      ])

    assert apply_output =~ "approved"
    refute apply_output =~ context.subject

    report_output =
      run_assignments_task(["report", assignment.capture_id, roster_path])

    assert report_output =~ "approved"
    refute report_output =~ context.subject
  end

  defp stage!(context) do
    {:ok, result} =
      Assignments.stage(
        context.roster,
        stage_rows(context),
        context.preparer.id,
        context.options
      )

    assignment = Repo.get!(StagedAssignment, hd(result.rows).assignment_id)
    {assignment, result.capture_id}
  end

  defp stage_rows(context) do
    [
      %{
        "principal_id" => context.target.id,
        "discord_user_id" => context.subject,
        "username_snapshot" => "target-user"
      }
    ]
  end

  defp review_rows(assignment, decision) do
    [%{"assignment_id" => assignment.id, "decision" => decision}]
  end

  defp run_assignments_task(args) do
    Mix.Task.reenable("dhc.discord.assignments")

    capture_io(fn ->
      Mix.Tasks.Dhc.Discord.Assignments.run(args)
    end)
  end

  defp write_json!(directory, name, value) do
    path = Path.join(directory, name)
    File.write!(path, Jason.encode!(value))
    path
  end

  defp member_fixture(label, role \\ nil) do
    id = Ecto.UUID.generate()
    email = "plain-assignment-#{label}-#{System.unique_integer([:positive])}@example.com"
    Dhc.MemberFixtures.member_fixture(%{principal_id: id, email: email})

    if role do
      Repo.insert_all("user_roles", [[principal_id: Ecto.UUID.dump!(id), role: role]])
    end

    %{id: id, email: email}
  end

  defp unique_subject, do: "plain-assignment-subject-#{System.unique_integer([:positive])}"
end
