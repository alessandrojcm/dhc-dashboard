defmodule Dhc.Discord.AssignmentsTest do
  use Dhc.DataCase, async: false

  import ExUnit.CaptureIO

  alias Dhc.Auth.{ExternalIdentity, UserRole}

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    AssignmentStageResult,
    Assignments,
    RosterDigest,
    RosterPackage,
    RosterReceipt,
    RosterReceipts,
    SignedManifest,
    StagedAssignment,
    StagedAssignmentAuditEvent
  }

  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo

  setup do
    preparer = member_fixture("preparer", "admin")
    reviewer = member_fixture("reviewer", "president")
    target = member_fixture("target")
    subject = unique_subject()

    capture =
      capture_fixture(preparer.id, [
        %{
          "id" => subject,
          "username" => "target-user",
          "global_name" => "Target",
          "nickname" => "Club Target"
        }
      ])

    options = %{
      manifest_keys: %{
        preparer.id => "preparer-manifest-test-key",
        reviewer.id => "reviewer-manifest-test-key"
      },
      fingerprint_key: "fingerprint-test-key",
      package_key: capture.package_key,
      package_path: capture.package_path,
      tool_revision: "ale-217-test"
    }

    on_exit(fn -> File.rm_rf(capture.package_dir) end)

    %{
      preparer: preparer,
      reviewer: reviewer,
      target: target,
      subject: subject,
      capture: capture,
      options: options
    }
  end

  test "stages only exact capture rows and replays without duplicate assignments or audits",
       context do
    command = stage_command(context)
    envelope = sign(command, context.options)

    assert {:ok, first} = Assignments.stage_signed(envelope, context.options)
    assert first.counts == %{"proposed" => 1}
    [row] = first.rows
    assert row.principal_id == context.target.id
    refute inspect(first) =~ context.subject
    refute inspect(first) =~ "target-user"

    assert {:ok, replay} = Assignments.stage_signed(envelope, context.options)
    assert replay.execution_id == first.execution_id
    assert Repo.aggregate(StagedAssignment, :count) == 1
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 1

    [event] = Repo.all(StagedAssignmentAuditEvent)
    assignment = Repo.get!(StagedAssignment, row.assignment_id)
    assert event.action == "proposed"
    assert event.actor_principal_id == context.preparer.id
    assert event.stage_execution_id == assignment.stage_execution_id
    refute Map.has_key?(Map.from_struct(event), :provider_subject)
    refute inspect(event) =~ context.subject
    refute inspect(event) =~ "target-user"

    changed = put_in(command, ["rows", Access.at(0), "username_snapshot"], "wrong-name")

    assert {:error, :row_not_in_capture} =
             Assignments.stage_signed(
               sign(changed, context.options),
               context.options
             )
  end

  test "signatures authenticate the named preparer and reviewer with distinct keys", context do
    stage_command = stage_command(context)

    forged_stage =
      SignedManifest.sign(
        stage_command,
        context.preparer.id,
        Map.fetch!(context.options.manifest_keys, context.reviewer.id)
      )

    assert {:error, :invalid_manifest_signature} =
             Assignments.stage_signed(forged_stage, context.options)

    reviewer_signed_stage =
      SignedManifest.sign(
        stage_command,
        context.reviewer.id,
        Map.fetch!(context.options.manifest_keys, context.reviewer.id)
      )

    assert {:error, :manifest_signer_mismatch} =
             Assignments.stage_signed(reviewer_signed_stage, context.options)

    assignment = stage!(context)
    review_command = review_command(context, assignment, "approve")

    shared_key = Map.fetch!(context.options.manifest_keys, context.preparer.id)

    duplicate_key_options = %{
      context.options
      | manifest_keys: %{
          context.preparer.id => shared_key,
          context.reviewer.id => shared_key
        }
    }

    impersonated_review =
      SignedManifest.sign(review_command, context.reviewer.id, shared_key)

    assert {:error, :invalid_manifest_signature} =
             Assignments.apply_review_signed(impersonated_review, duplicate_key_options)

    preparer_signed_review =
      SignedManifest.sign(
        review_command,
        context.preparer.id,
        Map.fetch!(context.options.manifest_keys, context.preparer.id)
      )

    assert {:error, :manifest_signer_mismatch} =
             Assignments.apply_review_signed(preparer_signed_review, context.options)

    assert Repo.aggregate(StagedAssignment, :count) == 1
    assert Repo.aggregate(AssignmentReviewExecution, :count) == 0
  end

  test "malformed signed rows and unknown Principals fail closed without task crashes", context do
    malformed_stage = put_in(stage_command(context), ["rows"], ["not-a-row"])

    assert {:error, :invalid_stage_manifest} =
             Assignments.stage_signed(sign(malformed_stage, context.options), context.options)

    unknown =
      context
      |> stage_command()
      |> put_in(["rows", Access.at(0), "principal_id"], Ecto.UUID.generate())

    assert {:error, :unknown_principal} =
             Assignments.stage_signed(sign(unknown, context.options), context.options)

    invalid_review = %{
      "version" => 1,
      "capture_id" => context.capture.id,
      "reviewer_principal_id" => context.reviewer.id,
      "rows" => ["not-a-row"]
    }

    assert {:error, :invalid_review_manifest} =
             Assignments.apply_review_signed(
               sign(invalid_review, context.options),
               context.options
             )

    assert Repo.aggregate(AssignmentStageExecution, :count) == 0
    assert Repo.aggregate(AssignmentReviewExecution, :count) == 0
  end

  test "capture digest authenticates metadata and roster receipts are immutable", context do
    {:ok, package} = RosterPackage.read(context.capture.package_path, context.options.package_key)

    tampered =
      Map.put(
        package,
        "captured_at",
        DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
      )

    {:ok, _} =
      RosterPackage.write(
        context.capture.package_dir,
        context.capture.id,
        tampered,
        context.options.package_key
      )

    assert {:error, :capture_receipt_digest_mismatch} =
             Assignments.stage_signed(
               sign(stage_command(context), context.options),
               context.options
             )

    capture = Repo.get!(RosterReceipt, context.capture.id)

    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn -> capture |> Ecto.Changeset.change(result: "rewritten") |> Repo.update!() end,
          mode: :savepoint
        )
      end

    assert error.constraint == "discord_roster_receipts_immutable"

    consistency_error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            assert {:ok, _} =
                     RosterReceipts.create(%{
                       id: Ecto.UUID.generate(),
                       kind: :capture,
                       status: :succeeded,
                       actor_id: context.preparer.id,
                       guild_id: "other-guild",
                       bot_application_id: "bot-217",
                       tool_revision: "ale-217-capture-test",
                       evidence_digest: digest_json(%{inconsistent: true}),
                       package_digest: String.duplicate("a", 64),
                       record_count: 1,
                       result: "inconsistent capture",
                       preflight_receipt_id: context.capture.preflight_id
                     })

            Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
          end,
          mode: :savepoint
        )
      end

    assert consistency_error.postgres.constraint in [
             "discord_roster_receipts_preflight_consistency",
             "discord_roster_receipts_capture_consistency"
           ]
  end

  test "independent review exposes exact restricted evidence and applies one explicit decision",
       context do
    assignment = stage!(context)

    assert {:error, :reviewer_must_differ_from_preparer} =
             Assignments.review_evidence(
               context.capture.id,
               context.preparer.id,
               context.options
             )

    assert {:ok, [evidence]} =
             Assignments.review_evidence(
               context.capture.id,
               context.reviewer.id,
               context.options
             )

    assert evidence == %{
             assignment_id: assignment.id,
             principal_id: context.target.id,
             discord_user_id: context.subject,
             username_snapshot: "target-user",
             global_name: "Target",
             nickname: "Club Target",
             capture_id: context.capture.id,
             proposal_digest: assignment.proposal_digest
           }

    command = review_command(context, assignment, "approve")
    envelope = sign(command, context.options)

    assert {:ok, first} = Assignments.apply_review_signed(envelope, context.options)
    assert first.counts == %{"approved" => 1}
    refute inspect(first) =~ context.subject
    refute inspect(first) =~ "target-user"
    assert Repo.get!(StagedAssignment, assignment.id).state == "approved"
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 2

    assert {:ok, replay} = Assignments.apply_review_signed(envelope, context.options)
    assert replay.execution_id == first.execution_id
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 2

    stale = put_in(command, ["rows", Access.at(0), "decision"], "reject")

    assert {:error, :stale_or_unreviewable_proposal} =
             Assignments.apply_review_signed(
               sign(stale, context.options),
               context.options
             )
  end

  test "approved review replays remain historical after a later withdrawal", context do
    assignment = stage!(context)
    envelope = sign(review_command(context, assignment, "approve"), context.options)

    assert {:ok, first} = Assignments.apply_review_signed(envelope, context.options)

    withdrawal = %{
      "version" => 1,
      "action" => "withdraw",
      "assignment_id" => assignment.id,
      "proposal_digest" => assignment.proposal_digest,
      "actor_principal_id" => context.reviewer.id,
      "reason_code" => "operator_withdrawal"
    }

    assert {:ok, %{state: "withdrawn"}} =
             Assignments.withdraw_signed(sign(withdrawal, context.options), context.options)

    assert {:ok, replay} = Assignments.apply_review_signed(envelope, context.options)
    assert replay.execution_id == first.execution_id
    assert replay.rows == first.rows
    assert [%{state: "approved"}] = replay.rows
    assert Repo.get!(StagedAssignment, assignment.id).state == "withdrawn"
  end

  test "rejected review attempts persist one immutable idempotency receipt", context do
    assignment = stage!(context)

    command =
      context
      |> review_command(assignment, "approve")
      |> put_in(["rows", Access.at(0), "proposal_digest"], String.duplicate("0", 64))

    envelope = sign(command, context.options)

    assert {:error, :stale_or_unreviewable_proposal} =
             Assignments.apply_review_signed(envelope, context.options)

    assert {:error, :stale_or_unreviewable_proposal} =
             Assignments.apply_review_signed(envelope, context.options)

    execution = Repo.one!(AssignmentReviewExecution)
    assert execution.state == "rejected"
    assert execution.reason_code == "stale_or_unreviewable_proposal"
    assert Repo.aggregate(AssignmentReviewExecution, :count) == 1

    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn ->
            execution |> Ecto.Changeset.change(reason_code: "rewritten") |> Repo.update!()
          end,
          mode: :savepoint
        )
      end

    assert error.constraint == "discord_assignment_review_executions_immutable"
  end

  test "stage and review evidence rows are immutable and audit rows are trigger-owned", context do
    assignment = stage!(context)

    assert {:ok, _} =
             Assignments.apply_review_signed(
               sign(review_command(context, assignment, "approve"), context.options),
               context.options
             )

    stage_execution = Repo.one!(AssignmentStageExecution)
    stage_result = Repo.one!(AssignmentStageResult)
    review_execution = Repo.one!(AssignmentReviewExecution)
    audit = Repo.one!(from e in StagedAssignmentAuditEvent, limit: 1)

    immutable = [
      {stage_execution, "discord_assignment_stage_executions_immutable"},
      {stage_result, "discord_assignment_stage_results_immutable"},
      {review_execution, "discord_assignment_review_executions_immutable"}
    ]

    Enum.each(immutable, fn {record, constraint} ->
      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.transaction(
            fn -> Repo.delete!(record) end,
            mode: :savepoint
          )
        end

      assert error.constraint == constraint
    end)

    update_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn -> audit |> Ecto.Changeset.change(reason_code: "rewritten") |> Repo.update!() end,
          mode: :savepoint
        )
      end

    assert update_error.constraint == "staged_discord_assignment_audit_events_immutable"

    delete_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> Repo.delete!(audit) end, mode: :savepoint)
      end

    assert delete_error.constraint == "staged_discord_assignment_audit_events_immutable"

    direct = %StagedAssignmentAuditEvent{
      assignment_id: assignment.id,
      action: "approved",
      actor_principal_id: context.reviewer.id,
      reason_code: "forged",
      old_state: "proposed",
      new_state: "approved",
      capture_id: assignment.capture_id,
      stage_execution_id: assignment.stage_execution_id,
      tool_revision: assignment.tool_revision,
      subject_fingerprint: assignment.subject_fingerprint
    }

    insert_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> Repo.insert!(direct) end, mode: :savepoint)
      end

    assert insert_error.constraint == "staged_discord_assignment_audit_events_trigger_owned"
  end

  test "reject is terminal and an approved or proposed row can be withdrawn without editing identity evidence",
       context do
    assignment = stage!(context)
    reject = review_command(context, assignment, "reject")

    assert {:ok, _} =
             Assignments.apply_review_signed(
               sign(reject, context.options),
               context.options
             )

    rejected = Repo.get!(StagedAssignment, assignment.id)
    assert rejected.state == "rejected"
    assert rejected.provider_subject == context.subject
    assert rejected.username_snapshot == "target-user"

    second_subject = unique_subject()

    second_capture =
      capture_fixture(context.preparer.id, [
        %{
          "id" => second_subject,
          "username" => "replacement",
          "global_name" => nil,
          "nickname" => nil
        }
      ])

    on_exit(fn -> File.rm_rf(second_capture.package_dir) end)

    options = %{
      context.options
      | package_key: second_capture.package_key,
        package_path: second_capture.package_path
    }

    second_context = %{
      context
      | capture: second_capture,
        subject: second_subject,
        options: options
    }

    proposed = stage!(second_context, "replacement")

    withdraw = %{
      "version" => 1,
      "action" => "withdraw",
      "assignment_id" => proposed.id,
      "proposal_digest" => proposed.proposal_digest,
      "actor_principal_id" => context.reviewer.id,
      "reason_code" => "operator_correction"
    }

    assert {:ok, %{state: "withdrawn"}} =
             Assignments.withdraw_signed(
               sign(withdraw, options),
               options
             )

    withdrawn = Repo.get!(StagedAssignment, proposed.id)
    assert withdrawn.provider_subject == second_subject
    assert withdrawn.username_snapshot == "replacement"
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 4
  end

  test "superseding preserves the old evidence and requires fresh independent review", context do
    old = stage!(context)
    replacement_subject = unique_subject()

    replacement_capture =
      capture_fixture(context.preparer.id, [
        %{
          "id" => replacement_subject,
          "username" => "corrected-user",
          "global_name" => "Corrected",
          "nickname" => nil
        }
      ])

    on_exit(fn -> File.rm_rf(replacement_capture.package_dir) end)

    options = %{
      context.options
      | package_key: replacement_capture.package_key,
        package_path: replacement_capture.package_path
    }

    command = %{
      "version" => 1,
      "action" => "supersede",
      "capture_id" => replacement_capture.id,
      "assignment_id" => old.id,
      "proposal_digest" => old.proposal_digest,
      "actor_principal_id" => context.reviewer.id,
      "row" => %{
        "principal_id" => context.target.id,
        "discord_user_id" => replacement_subject,
        "username_snapshot" => "corrected-user"
      }
    }

    envelope = sign(command, options)
    assert {:ok, first} = Assignments.supersede_signed(envelope, options)
    assert first.superseded_assignment_id == old.id

    old_after = Repo.get!(StagedAssignment, old.id)
    replacement = Repo.get!(StagedAssignment, first.replacement.assignment_id)

    assert old_after.state == "superseded"
    assert old_after.provider_subject == context.subject
    assert old_after.username_snapshot == "target-user"
    assert replacement.state == "proposed"
    assert replacement.provider_subject == replacement_subject
    assert replacement.username_snapshot == "corrected-user"
    assert replacement.prepared_by_principal_id == context.reviewer.id
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 3

    assert {:ok, replay} = Assignments.supersede_signed(envelope, options)
    assert replay == first
    assert Repo.aggregate(StagedAssignment, :count) == 2
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 3

    review_context = %{
      context
      | capture: replacement_capture,
        reviewer: context.preparer,
        options: options
    }

    review = review_command(review_context, replacement, "approve")

    assert {:ok, %{counts: %{"approved" => 1}}} =
             Assignments.apply_review_signed(
               sign(review, options),
               options
             )

    assert Repo.get!(StagedAssignment, replacement.id).state == "approved"
    assert Repo.aggregate(StagedAssignmentAuditEvent, :count) == 4
  end

  test "final report counts captured proposals and current safe outcomes without duplicating conflicts as omissions",
       context do
    conflicted_target = member_fixture("conflicted-target")
    conflicted_subject = unique_subject()
    omitted_subject = unique_subject()

    capture =
      capture_fixture(context.preparer.id, [
        %{
          "id" => context.subject,
          "username" => "target-user",
          "global_name" => "Target",
          "nickname" => nil
        },
        %{
          "id" => conflicted_subject,
          "username" => "claimed-user",
          "global_name" => nil,
          "nickname" => nil
        },
        %{
          "id" => omitted_subject,
          "username" => "omitted-user",
          "global_name" => nil,
          "nickname" => nil
        }
      ])

    on_exit(fn -> File.rm_rf(capture.package_dir) end)

    options = %{
      context.options
      | package_key: capture.package_key,
        package_path: capture.package_path
    }

    claim_fixture(conflicted_subject)

    stage = %{
      "version" => 1,
      "capture_id" => capture.id,
      "preparer_principal_id" => context.preparer.id,
      "rows" => [
        %{
          "principal_id" => context.target.id,
          "discord_user_id" => context.subject,
          "username_snapshot" => "target-user"
        },
        %{
          "principal_id" => conflicted_target.id,
          "discord_user_id" => conflicted_subject,
          "username_snapshot" => "claimed-user"
        }
      ]
    }

    assert {:ok, %{counts: %{"conflicted" => 1, "proposed" => 1}} = staged} =
             Assignments.stage_signed(sign(stage, options), options)

    assignment_id =
      staged.rows
      |> Enum.find(&(&1.state == "proposed"))
      |> Map.fetch!(:assignment_id)

    assignment = Repo.get!(StagedAssignment, assignment_id)

    review_context = %{context | capture: capture, options: options}
    review = review_command(review_context, assignment, "approve")

    assert {:ok, _} =
             Assignments.apply_review_signed(
               sign(review, options),
               options
             )

    assert {:ok, report} = Assignments.report(capture.id, options)

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
    refute inspect(report) =~ "target-user"
    refute inspect(report) =~ "claimed-user"
    refute inspect(report) =~ "omitted-user"
  end

  test "final report distinguishes promoted, rejected, and unresolved rows", context do
    rejected_target = member_fixture("report-rejected")
    unresolved_target = member_fixture("report-unresolved")
    subjects = [context.subject, unique_subject(), unique_subject()]
    targets = [context.target, rejected_target, unresolved_target]

    users =
      subjects
      |> Enum.with_index(1)
      |> Enum.map(fn {subject, index} ->
        %{
          "id" => subject,
          "username" => "report-user-#{index}",
          "global_name" => nil,
          "nickname" => nil
        }
      end)

    capture = capture_fixture(context.preparer.id, users)
    on_exit(fn -> File.rm_rf(capture.package_dir) end)

    options = %{
      context.options
      | package_key: capture.package_key,
        package_path: capture.package_path
    }

    rows =
      [targets, subjects]
      |> Enum.zip()
      |> Enum.with_index(1)
      |> Enum.map(fn {{target, subject}, index} ->
        %{
          "principal_id" => target.id,
          "discord_user_id" => subject,
          "username_snapshot" => "report-user-#{index}"
        }
      end)

    command = %{
      "version" => 1,
      "capture_id" => capture.id,
      "preparer_principal_id" => context.preparer.id,
      "rows" => rows
    }

    assert {:ok, %{counts: %{"proposed" => 3}}} =
             Assignments.stage_signed(sign(command, options), options)

    assignments = Repo.all(from a in StagedAssignment, where: a.capture_id == ^capture.id)
    [approved, rejected, _unresolved] = Enum.sort_by(assignments, & &1.principal_id)

    review = %{
      "version" => 1,
      "capture_id" => capture.id,
      "reviewer_principal_id" => context.reviewer.id,
      "rows" => [
        %{
          "assignment_id" => approved.id,
          "proposal_digest" => approved.proposal_digest,
          "decision" => "approve"
        },
        %{
          "assignment_id" => rejected.id,
          "proposal_digest" => rejected.proposal_digest,
          "decision" => "reject"
        }
      ]
    }

    assert {:ok, %{counts: %{"approved" => 1, "rejected" => 1}}} =
             Assignments.apply_review_signed(sign(review, options), options)

    approved = Repo.get!(StagedAssignment, approved.id)

    approved
    |> StagedAssignment.transition_changeset(%{
      state: "promoted",
      terminal_at: DateTime.utc_now(),
      terminal_actor_principal_id: context.reviewer.id,
      reason_code: "discord_identity_promoted"
    })
    |> Repo.update!()

    assert {:ok, report} = Assignments.report(capture.id, options)

    assert report.counts == %{
             "approved" => 0,
             "captured" => 3,
             "conflicted" => 0,
             "omitted" => 0,
             "promoted" => 1,
             "proposed" => 3,
             "rejected" => 1,
             "unresolved" => 1
           }

    assert report.rows |> Enum.map(& &1.outcome) |> Enum.sort() ==
             ["promoted", "rejected", "unresolved"]
  end

  test "active claims and permanent identities are reported as conflicts without unsafe receipt data",
       context do
    claim_fixture(context.subject)

    assert {:ok, claim_result} =
             Assignments.stage_signed(
               sign(stage_command(context), context.options),
               context.options
             )

    assert claim_result.counts == %{"conflicted" => 1}
    assert hd(claim_result.rows).reason_code == "active_claim_collision"
    refute inspect(claim_result) =~ context.subject
    refute inspect(claim_result) =~ "target-user"

    other_subject = unique_subject()

    other_capture =
      capture_fixture(context.preparer.id, [
        %{"id" => other_subject, "username" => "linked", "global_name" => nil, "nickname" => nil}
      ])

    on_exit(fn -> File.rm_rf(other_capture.package_dir) end)

    options = %{
      context.options
      | package_key: other_capture.package_key,
        package_path: other_capture.package_path
    }

    Repo.insert!(%ExternalIdentity{
      principal_id: context.target.id,
      provider: "discord",
      provider_subject: other_subject,
      metadata: %{}
    })

    command =
      stage_command(%{context | capture: other_capture, subject: other_subject}, "linked")

    assert {:ok, identity_result} =
             Assignments.stage_signed(sign(command, options), options)

    assert hd(identity_result.rows).reason_code == "permanent_identity_collision"
  end

  test "database rejects identity-field edits and audit mutation", context do
    assignment = stage!(context)
    event = Repo.one!(StagedAssignmentAuditEvent)

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

    audit_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> Repo.delete!(event) end, mode: :savepoint)
      end

    assert audit_error.constraint == "staged_discord_assignment_audit_events_immutable"
  end

  test "database rejects lifecycle evidence edits without a state transition", context do
    assignment = stage!(context)
    review = review_command(context, assignment, "approve")

    assert {:ok, _} =
             Assignments.apply_review_signed(
               sign(review, context.options),
               context.options
             )

    approved = Repo.get!(StagedAssignment, assignment.id)

    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn ->
            approved
            |> Ecto.Changeset.change(approved_at: DateTime.add(approved.approved_at, 1, :second))
            |> Repo.update!()
          end,
          mode: :savepoint
        )
      end

    assert error.constraint == "staged_discord_assignments_lifecycle_immutable"
  end

  test "database requires review execution to match the capture and independent reviewer",
       context do
    assignment = stage!(context)
    now = DateTime.utc_now()

    same_preparer_review =
      %AssignmentReviewExecution{}
      |> AssignmentReviewExecution.changeset(%{
        capture_id: context.capture.id,
        manifest_digest: digest_json(%{review: Ecto.UUID.generate()}),
        reviewer_principal_id: context.preparer.id,
        tool_revision: context.options.tool_revision,
        executed_at: now,
        state: "applied"
      })
      |> Repo.insert!()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            assignment
            |> StagedAssignment.transition_changeset(%{
              state: "rejected",
              review_execution_id: same_preparer_review.id,
              terminal_at: now,
              terminal_actor_principal_id: context.preparer.id,
              reason_code: "review_rejected"
            })
            |> Repo.update!()

            Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.constraint ==
             "staged_discord_assignments_review_execution_consistency"
  end

  test "reciprocal database constraint rejects a permanent link overlapping an active assignment",
       context do
    _assignment = stage!(context)

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

  test "reciprocal database constraint rejects a claim overlapping an active assignment",
       context do
    _assignment = stage!(context)
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
    continuation_id = acceptance_continuation_fixture()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            Repo.insert!(%InvitationAcceptanceDiscordSubjectClaim{
              continuation_id: continuation_id,
              provider: "discord",
              provider_subject: context.subject
            })

            Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.constraint == "discord_subject_claims_active_assignment_conflict"
  end

  test "invitation acceptance reports an active assignment as a neutral Discord collision",
       context do
    _assignment = stage!(context)
    continuation_id = acceptance_continuation_fixture()

    assert {:error, :collision} =
             Onboarding.verify_discord(continuation_id, %{
               "sub" => context.subject,
               "preferred_username" => "claimed"
             })

    refute Repo.exists?(
             from(c in InvitationAcceptanceDiscordSubjectClaim,
               where: c.provider == "discord" and c.provider_subject == ^context.subject
             )
           )
  end

  test "concurrent stage manifests serialize and leave one active subject owner", context do
    second_target = member_fixture("second-target")
    task_supervisor = start_supervised!(Task.Supervisor)

    first =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Assignments.stage_signed(
          sign(stage_command(context), context.options),
          context.options
        )
      end)

    second_command =
      context
      |> stage_command()
      |> put_in(["rows", Access.at(0), "principal_id"], second_target.id)

    second =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Assignments.stage_signed(
          sign(second_command, context.options),
          context.options
        )
      end)

    results = [Task.await(first), Task.await(second)]

    outcomes =
      Enum.map(results, fn {:ok, result} -> result.rows |> hd() |> Map.fetch!(:state) end)

    assert Enum.sort(outcomes) == ["conflicted", "proposed"]

    assert Repo.aggregate(
             from(a in StagedAssignment, where: a.state in ["proposed", "approved"]),
             :count
           ) == 1
  end

  test "independent PostgreSQL connections serialize claims, links, and role revocation" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    external =
      supervisor
      |> unboxed_async(fn -> external_race_context() end)
      |> Task.await()

    on_exit(fn ->
      cleanup_external_race_context(external)
      File.rm_rf(external.capture.package_dir)
    end)

    [claim_subject, identity_subject, revoked_subject] = external.subjects
    [claim_target, identity_target, revoked_target] = external.targets

    claim_stage_command =
      stage_command_for(external, claim_target.id, claim_subject, "race-1")

    claim_stage =
      unboxed_async(supervisor, fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> :ok)
        Assignments.stage_signed(sign(claim_stage_command, external.options), external.options)
      end)

    claim =
      unboxed_async(supervisor, fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> :ok)

        Onboarding.verify_discord(external.continuation_id, %{
          "sub" => claim_subject,
          "preferred_username" => "claim-race"
        })
      end)

    assert_receive {:ready, claim_stage_pid}
    assert_receive {:ready, claim_pid}
    send(claim_stage_pid, :go)
    send(claim_pid, :go)

    {:ok, claim_stage_result} = Task.await(claim_stage)
    claim_result = Task.await(claim)
    claim_stage_state = claim_stage_result.rows |> hd() |> Map.fetch!(:state)

    case {claim_stage_state, claim_result} do
      {"proposed", {:error, :collision}} -> :ok
      {"conflicted", {:ok, _claim}} -> :ok
    end

    identity_stage_command =
      stage_command_for(external, identity_target.id, identity_subject, "race-2")

    identity_stage =
      unboxed_async(supervisor, fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> :ok)
        Assignments.stage_signed(sign(identity_stage_command, external.options), external.options)
      end)

    identity =
      unboxed_async(supervisor, fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> :ok)

        Repo.transaction(fn ->
          Repo.insert!(%ExternalIdentity{
            principal_id: identity_target.id,
            provider: "discord",
            provider_subject: identity_subject,
            metadata: %{}
          })

          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
          :linked
        end)
      end)

    assert_receive {:ready, identity_stage_pid}
    assert_receive {:ready, identity_pid}
    send(identity_stage_pid, :go)
    send(identity_pid, :go)

    {:ok, identity_stage_result} = Task.await(identity_stage)
    identity_result = Task.await(identity)
    identity_stage_state = identity_stage_result.rows |> hd() |> Map.fetch!(:state)

    assert (identity_stage_state == "proposed" and match?({:error, _}, identity_result)) or
             (identity_stage_state == "conflicted" and identity_result == {:ok, :linked})

    revoked_stage_command =
      stage_command_for(external, revoked_target.id, revoked_subject, "race-3")

    revoker =
      unboxed_async(supervisor, fn ->
        Repo.transaction(fn ->
          from(r in UserRole,
            where: r.principal_id == ^external.preparer.id and r.role == "admin"
          )
          |> Repo.delete_all()

          send(parent, {:revocation_locked, self()})
          receive do: (:commit_revocation -> :ok)
        end)
      end)

    assert_receive {:revocation_locked, revoker_pid}

    revoked_stage =
      unboxed_async(supervisor, fn ->
        send(parent, :revoked_stage_started)
        Assignments.stage_signed(sign(revoked_stage_command, external.options), external.options)
      end)

    assert_receive :revoked_stage_started
    assert Task.yield(revoked_stage, 0) == nil
    send(revoker_pid, :commit_revocation)
    assert {:ok, _} = Task.await(revoker)
    assert {:error, :unauthorized_principal} = Task.await(revoked_stage)
  end

  test "operator task exercises every phase and limits raw evidence to review", context do
    manifest_path = Path.join(context.capture.package_dir, "stage-manifest.json")
    envelope = sign(stage_command(context), context.options)
    File.write!(manifest_path, Jason.encode!(envelope))

    env = %{
      "DISCORD_ASSIGNMENT_MANIFEST_KEYS" => Jason.encode!(context.options.manifest_keys),
      "DISCORD_SUBJECT_FINGERPRINT_KEY" => context.options.fingerprint_key,
      "DISCORD_ROSTER_PACKAGE_KEY" => context.options.package_key,
      "DISCORD_ASSIGNMENT_TOOL_REVISION" => context.options.tool_revision
    }

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    stage_output =
      run_assignments_task(["stage", manifest_path, context.capture.package_path])

    assert_safe_task_output(stage_output, context)
    assignment = Repo.one!(StagedAssignment)

    review_output =
      run_assignments_task([
        "review",
        context.capture.id,
        context.reviewer.id,
        context.capture.package_path
      ])

    assert review_output =~ context.subject
    assert review_output =~ "target-user"
    refute review_output =~ context.target.email

    review_path = Path.join(context.capture.package_dir, "review-manifest.json")

    File.write!(
      review_path,
      Jason.encode!(sign(review_command(context, assignment, "approve"), context.options))
    )

    apply_output = run_assignments_task(["apply-review", review_path])
    assert_safe_task_output(apply_output, context)

    report_output =
      run_assignments_task(["report", context.capture.id, context.capture.package_path])

    assert_safe_task_output(report_output, context)
    assert report_output =~ "approved"

    replacement_subject = unique_subject()

    replacement_capture =
      capture_fixture(context.reviewer.id, [
        %{
          "id" => replacement_subject,
          "username" => "replacement-user",
          "global_name" => nil,
          "nickname" => nil
        }
      ])

    on_exit(fn -> File.rm_rf(replacement_capture.package_dir) end)

    replacement_options = %{
      context.options
      | package_key: replacement_capture.package_key,
        package_path: replacement_capture.package_path
    }

    supersede_command = %{
      "version" => 1,
      "action" => "supersede",
      "capture_id" => replacement_capture.id,
      "assignment_id" => assignment.id,
      "proposal_digest" => assignment.proposal_digest,
      "actor_principal_id" => context.reviewer.id,
      "row" => %{
        "principal_id" => context.target.id,
        "discord_user_id" => replacement_subject,
        "username_snapshot" => "replacement-user"
      }
    }

    supersede_path = Path.join(replacement_capture.package_dir, "supersede-manifest.json")
    File.write!(supersede_path, Jason.encode!(sign(supersede_command, replacement_options)))
    System.put_env("DISCORD_ROSTER_PACKAGE_KEY", replacement_capture.package_key)

    supersede_output =
      run_assignments_task(["supersede", supersede_path, replacement_capture.package_path])

    refute supersede_output =~ replacement_subject
    refute supersede_output =~ "replacement-user"
    replacement = Repo.get_by!(StagedAssignment, capture_id: replacement_capture.id)

    withdraw_command = %{
      "version" => 1,
      "action" => "withdraw",
      "assignment_id" => replacement.id,
      "proposal_digest" => replacement.proposal_digest,
      "actor_principal_id" => context.preparer.id,
      "reason_code" => "operator_correction"
    }

    withdraw_path = Path.join(replacement_capture.package_dir, "withdraw-manifest.json")
    File.write!(withdraw_path, Jason.encode!(sign(withdraw_command, replacement_options)))
    withdraw_output = run_assignments_task(["withdraw", withdraw_path])

    refute withdraw_output =~ replacement_subject
    refute withdraw_output =~ "replacement-user"
    assert withdraw_output =~ "withdrawn"
  end

  defp stage!(context, username_snapshot \\ "target-user") do
    command = stage_command(context, username_snapshot)

    {:ok, result} =
      Assignments.stage_signed(
        sign(command, context.options),
        context.options
      )

    Repo.get!(StagedAssignment, hd(result.rows).assignment_id)
  end

  defp stage_command(context, username_snapshot \\ "target-user") do
    %{
      "version" => 1,
      "capture_id" => context.capture.id,
      "preparer_principal_id" => context.preparer.id,
      "rows" => [
        %{
          "principal_id" => context.target.id,
          "discord_user_id" => context.subject,
          "username_snapshot" => username_snapshot
        }
      ]
    }
  end

  defp review_command(context, assignment, decision) do
    %{
      "version" => 1,
      "capture_id" => context.capture.id,
      "reviewer_principal_id" => context.reviewer.id,
      "rows" => [
        %{
          "assignment_id" => assignment.id,
          "proposal_digest" => assignment.proposal_digest,
          "decision" => decision
        }
      ]
    }
  end

  defp run_assignments_task(args) do
    Mix.Task.reenable("dhc.discord.assignments")

    capture_io(fn ->
      Mix.Tasks.Dhc.Discord.Assignments.run(args)
    end)
  end

  defp assert_safe_task_output(output, context) do
    assert output =~ "subject_fingerprint"
    refute output =~ context.subject
    refute output =~ "target-user"
    refute output =~ context.target.email
  end

  defp unboxed_async(supervisor, fun) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
    end)
  end

  defp external_race_context do
    preparer = member_fixture("external-race-preparer", "admin")

    targets =
      Enum.map(1..3, fn index -> member_fixture("external-race-target-#{index}") end)

    subjects = Enum.map(1..3, fn _ -> unique_subject() end)

    users =
      subjects
      |> Enum.with_index(1)
      |> Enum.map(fn {subject, index} ->
        %{
          "id" => subject,
          "username" => "race-#{index}",
          "global_name" => nil,
          "nickname" => nil
        }
      end)

    capture = capture_fixture(preparer.id, users)

    %{
      preparer: preparer,
      targets: targets,
      subjects: subjects,
      continuation_id: acceptance_continuation_fixture(),
      capture: capture,
      options: %{
        manifest_keys: %{preparer.id => "external-race-manifest-key"},
        fingerprint_key: "external-race-fingerprint-key",
        package_key: capture.package_key,
        package_path: capture.package_path,
        tool_revision: "ale-217-test"
      }
    }
  end

  defp stage_command_for(context, principal_id, subject, username) do
    %{
      "version" => 1,
      "capture_id" => context.capture.id,
      "preparer_principal_id" => context.preparer.id,
      "rows" => [
        %{
          "principal_id" => principal_id,
          "discord_user_id" => subject,
          "username_snapshot" => username
        }
      ]
    }
  end

  defp cleanup_external_race_context(context) do
    principal_ids = [context.preparer.id | Enum.map(context.targets, & &1.id)]
    capture_id = Ecto.UUID.dump!(context.capture.id)
    receipt_ids = Enum.map([context.capture.id, context.capture.preflight_id], &Ecto.UUID.dump!/1)
    principal_ids = Enum.map(principal_ids, &Ecto.UUID.dump!/1)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("SET session_replication_role = replica")

      try do
        Repo.query!(
          "DELETE FROM staged_discord_assignment_audit_events WHERE assignment_id IN (SELECT id FROM staged_discord_assignments WHERE capture_id = $1)",
          [capture_id]
        )

        Repo.query!(
          "DELETE FROM discord_assignment_stage_results WHERE stage_execution_id IN (SELECT id FROM discord_assignment_stage_executions WHERE capture_id = $1)",
          [capture_id]
        )

        Repo.query!("DELETE FROM discord_assignment_review_executions WHERE capture_id = $1", [
          capture_id
        ])

        Repo.query!("DELETE FROM staged_discord_assignments WHERE capture_id = $1", [
          capture_id
        ])

        Repo.query!("DELETE FROM discord_assignment_stage_executions WHERE capture_id = $1", [
          capture_id
        ])

        Repo.query!("DELETE FROM discord_roster_receipts WHERE id = ANY($1::uuid[])", [
          receipt_ids
        ])

        Repo.query!("DELETE FROM external_identities WHERE provider_subject = ANY($1::text[])", [
          context.subjects
        ])

        Repo.query!(
          "DELETE FROM invitation_acceptance_discord_subject_claims WHERE provider_subject = ANY($1::text[])",
          [context.subjects]
        )

        Repo.query!("DELETE FROM user_roles WHERE principal_id = ANY($1::uuid[])", [principal_ids])

        Repo.query!("DELETE FROM member_profiles WHERE id = ANY($1::uuid[])", [principal_ids])

        Repo.query!("DELETE FROM user_profiles WHERE principal_id = ANY($1::uuid[])", [
          principal_ids
        ])

        Repo.query!("DELETE FROM principals WHERE id = ANY($1::uuid[])", [principal_ids])
      after
        Repo.query!("SET session_replication_role = origin")
      end
    end)
  end

  defp member_fixture(label, role \\ nil) do
    id = Ecto.UUID.generate()
    email = "ale-217-#{label}-#{System.unique_integer([:positive])}@example.com"
    Dhc.MemberFixtures.member_fixture(%{principal_id: id, email: email})

    if role do
      Repo.insert_all("user_roles", [[principal_id: Ecto.UUID.dump!(id), role: role]])
    end

    %{id: id, email: email}
  end

  defp capture_fixture(actor_id, users) do
    package_dir = Path.join(System.tmp_dir!(), "ale-217-#{System.unique_integer([:positive])}")
    package_key = Base.encode64(:crypto.strong_rand_bytes(32))
    tool_revision = "ale-217-capture-test"
    digest = RosterDigest.digest(users)

    {:ok, preflight} =
      RosterReceipts.create(%{
        kind: :preflight,
        status: :succeeded,
        actor_id: actor_id,
        guild_id: "guild-217",
        bot_application_id: "bot-217",
        tool_revision: tool_revision,
        evidence_digest: digest_json(%{preflight: true}),
        record_count: length(users),
        result: "guild-members endpoint available"
      })

    capture_id = Ecto.UUID.generate()

    package = %{
      "version" => 1,
      "capture_id" => capture_id,
      "guild_id" => "guild-217",
      "tool_revision" => tool_revision,
      "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "record_count" => length(users),
      "digest" => digest,
      "users" => users
    }

    package_digest = RosterDigest.package_digest(package)

    {:ok, package_path} = RosterPackage.write(package_dir, capture_id, package, package_key)

    {:ok, capture} =
      RosterReceipts.create(%{
        id: capture_id,
        kind: :capture,
        status: :succeeded,
        actor_id: actor_id,
        guild_id: "guild-217",
        bot_application_id: "bot-217",
        tool_revision: tool_revision,
        evidence_digest: digest_json(%{preflight_receipt_id: preflight.id}),
        package_digest: package_digest,
        record_count: length(users),
        result: "capture complete; no staged assignments created",
        preflight_receipt_id: preflight.id
      })

    %{
      id: capture.id,
      preflight_id: preflight.id,
      package_dir: package_dir,
      package_path: package_path,
      package_key: package_key
    }
  end

  defp claim_fixture(subject) do
    continuation_id = acceptance_continuation_fixture()

    assert {:ok, _} =
             Onboarding.verify_discord(continuation_id, %{
               "sub" => subject,
               "preferred_username" => "claimed"
             })
  end

  defp acceptance_continuation_fixture do
    invitation =
      %Invitation{
        email: "ale-217-claim-#{System.unique_integer([:positive])}@example.com",
        prospective_principal_id: Ecto.UUID.generate(),
        status: "pending",
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
        invitation_type: "member",
        first_name: "Claim",
        last_name: "Owner",
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01]
      }
      |> Repo.insert!()

    {:ok, state} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    state.continuation_id
  end

  defp unique_subject, do: "ale-217-subject-#{System.unique_integer([:positive])}"

  defp sign(command, options) do
    signer =
      command["preparer_principal_id"] || command["reviewer_principal_id"] ||
        command["actor_principal_id"]

    SignedManifest.sign(command, signer, Map.fetch!(options.manifest_keys, signer))
  end

  defp digest_json(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
