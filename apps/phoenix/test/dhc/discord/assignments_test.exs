defmodule Dhc.Discord.AssignmentsTest do
  use Dhc.DataCase, async: false

  import ExUnit.CaptureIO

  alias Dhc.Auth.ExternalIdentity

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    Assignments,
    RosterDigest,
    RosterPackage,
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
      manifest_key: "manifest-test-key",
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
    envelope = SignedManifest.sign(command, context.options.manifest_key)

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
               SignedManifest.sign(changed, context.options.manifest_key),
               context.options
             )
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
    envelope = SignedManifest.sign(command, context.options.manifest_key)

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
               SignedManifest.sign(stale, context.options.manifest_key),
               context.options
             )
  end

  test "reject is terminal and an approved or proposed row can be withdrawn without editing identity evidence",
       context do
    assignment = stage!(context)
    reject = review_command(context, assignment, "reject")

    assert {:ok, _} =
             Assignments.apply_review_signed(
               SignedManifest.sign(reject, context.options.manifest_key),
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
               SignedManifest.sign(withdraw, options.manifest_key),
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

    envelope = SignedManifest.sign(command, options.manifest_key)
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
               SignedManifest.sign(review, options.manifest_key),
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
             Assignments.stage_signed(SignedManifest.sign(stage, options.manifest_key), options)

    assignment_id =
      staged.rows
      |> Enum.find(&(&1.state == "proposed"))
      |> Map.fetch!(:assignment_id)

    assignment = Repo.get!(StagedAssignment, assignment_id)

    review_context = %{context | capture: capture, options: options}
    review = review_command(review_context, assignment, "approve")

    assert {:ok, _} =
             Assignments.apply_review_signed(
               SignedManifest.sign(review, options.manifest_key),
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

  test "active claims and permanent identities are reported as conflicts without unsafe receipt data",
       context do
    claim_fixture(context.subject)

    assert {:ok, claim_result} =
             Assignments.stage_signed(
               SignedManifest.sign(stage_command(context), context.options.manifest_key),
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
             Assignments.stage_signed(SignedManifest.sign(command, options.manifest_key), options)

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
               SignedManifest.sign(review, context.options.manifest_key),
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
        executed_at: now
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
          SignedManifest.sign(stage_command(context), context.options.manifest_key),
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
          SignedManifest.sign(second_command, context.options.manifest_key),
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

  test "operator task emits only safe staging receipt identifiers", context do
    manifest_path = Path.join(context.capture.package_dir, "stage-manifest.json")
    envelope = SignedManifest.sign(stage_command(context), context.options.manifest_key)
    File.write!(manifest_path, Jason.encode!(envelope))

    env = %{
      "DISCORD_ASSIGNMENT_MANIFEST_KEY" => context.options.manifest_key,
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

    Mix.Task.reenable("dhc.discord.assignments")

    output =
      capture_io(fn ->
        Mix.Tasks.Dhc.Discord.Assignments.run([
          "stage",
          manifest_path,
          context.capture.package_path
        ])
      end)

    assert output =~ "subject_fingerprint"
    refute output =~ context.subject
    refute output =~ "target-user"
    refute output =~ context.target.email
  end

  defp stage!(context, username_snapshot \\ "target-user") do
    command = stage_command(context, username_snapshot)

    {:ok, result} =
      Assignments.stage_signed(
        SignedManifest.sign(command, context.options.manifest_key),
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
        package_digest: digest,
        record_count: length(users),
        result: "capture complete; no staged assignments created",
        preflight_receipt_id: preflight.id
      })

    %{
      id: capture.id,
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

  defp digest_json(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
