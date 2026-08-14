defmodule Dhc.Discord.Assignments do
  @moduledoc """
  Controlled staging and independent review of existing-Member Discord assignments.

  All binding decisions use Principal UUIDs and immutable Discord subjects from
  one authenticated roster package. Names and email addresses are never selectors.
  """

  import Ecto.Query

  alias Dhc.Auth.{DiscordSubjectLock, ExternalIdentity, Principal, UserRole}

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    AssignmentStageResult,
    RosterDigest,
    RosterPackage,
    RosterReceipt,
    SignedManifest,
    StagedAssignment
  }

  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo

  @member_admin_roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)
  @active_states ~w(proposed approved)

  def stage_signed(envelope, options) do
    with {:ok, command, manifest_digest} <- SignedManifest.verify(envelope, options.manifest_key),
         :ok <- exact_stage_command(command),
         {:ok, package} <- RosterPackage.read(options.package_path, options.package_key),
         :ok <- validate_package(command["capture_id"], package) do
      stage(command, manifest_digest, package, options)
    end
  end

  def apply_review_signed(envelope, options) do
    with {:ok, command, manifest_digest} <- SignedManifest.verify(envelope, options.manifest_key),
         :ok <- exact_review_command(command) do
      apply_review(command, manifest_digest, options)
    end
  end

  def review_evidence(capture_id, reviewer_principal_id, options) do
    with :ok <- valid_uuid(capture_id),
         :ok <- valid_uuid(reviewer_principal_id),
         :ok <- authorize_member_admin(reviewer_principal_id),
         {:ok, package} <- RosterPackage.read(options.package_path, options.package_key),
         :ok <- validate_package(capture_id, package),
         {:ok, capture} <- verified_capture(capture_id) do
      assignments =
        Repo.all(
          from(a in StagedAssignment,
            where: a.capture_id == ^capture.id and a.state == "proposed",
            order_by: [asc: a.id]
          )
        )

      users = Map.new(package["users"], &{&1["id"], &1})

      if Enum.any?(assignments, &(&1.prepared_by_principal_id == reviewer_principal_id)) do
        {:error, :reviewer_must_differ_from_preparer}
      else
        {:ok,
         Enum.map(assignments, fn assignment ->
           user = Map.fetch!(users, assignment.provider_subject)

           %{
             assignment_id: assignment.id,
             principal_id: assignment.principal_id,
             discord_user_id: assignment.provider_subject,
             username_snapshot: assignment.username_snapshot,
             global_name: user["global_name"],
             nickname: user["nickname"],
             capture_id: assignment.capture_id,
             proposal_digest: assignment.proposal_digest
           }
         end)}
      end
    end
  end

  def withdraw_signed(envelope, options) do
    with {:ok, command, _digest} <- SignedManifest.verify(envelope, options.manifest_key),
         :ok <- exact_withdraw_command(command),
         :ok <- authorize_member_admin(command["actor_principal_id"]) do
      Repo.transaction(fn -> withdraw_locked(command) end) |> transaction_result()
    end
  end

  def supersede_signed(envelope, options) do
    with {:ok, command, manifest_digest} <- SignedManifest.verify(envelope, options.manifest_key),
         :ok <- exact_supersede_command(command),
         {:ok, package} <- RosterPackage.read(options.package_path, options.package_key),
         :ok <- validate_package(command["capture_id"], package),
         :ok <- authorize_member_admin(command["actor_principal_id"]) do
      supersede(command, manifest_digest, package, options)
    end
  end

  def report(capture_id, options) do
    with {:ok, package} <- RosterPackage.read(options.package_path, options.package_key),
         :ok <- validate_package(capture_id, package),
         {:ok, _capture} <- verified_capture(capture_id) do
      assignments = Repo.all(from(a in StagedAssignment, where: a.capture_id == ^capture_id))

      stage_results =
        Repo.all(
          from(r in AssignmentStageResult,
            join: e in AssignmentStageExecution,
            on: e.id == r.stage_execution_id,
            where: e.capture_id == ^capture_id
          )
        )

      assignments_by_fingerprint = Enum.group_by(assignments, & &1.subject_fingerprint)

      conflicts_by_fingerprint =
        stage_results
        |> Enum.filter(&(&1.outcome == "conflicted"))
        |> Enum.group_by(& &1.subject_fingerprint)

      rows =
        Enum.map(package["users"], fn user ->
          fingerprint = subject_fingerprint(user["id"], options.fingerprint_key)

          report_row(
            fingerprint,
            Map.get(assignments_by_fingerprint, fingerprint, []),
            Map.get(conflicts_by_fingerprint, fingerprint, [])
          )
        end)

      counts =
        %{
          "approved" => 0,
          "captured" => length(package["users"]),
          "conflicted" => 0,
          "omitted" => 0,
          "promoted" => 0,
          "proposed" => Enum.count(stage_results, &(&1.outcome == "proposed")),
          "rejected" => 0,
          "unresolved" => 0
        }
        |> Map.merge(Enum.frequencies_by(rows, & &1.outcome))

      {:ok, %{capture_id: capture_id, counts: counts, rows: rows}}
    end
  end

  defp stage(command, manifest_digest, package, options) do
    with :ok <- authorize_member_admin(command["preparer_principal_id"]),
         {:ok, _capture} <- verified_capture(command["capture_id"]),
         :ok <- validate_stage_rows(command["rows"], package) do
      Repo.transaction(fn ->
        lock_manifest!("stage", manifest_digest)

        case Repo.get_by(AssignmentStageExecution,
               capture_id: command["capture_id"],
               manifest_digest: manifest_digest
             ) do
          nil -> create_stage(command, manifest_digest, options)
          execution -> stage_receipt(execution)
        end
      end)
      |> transaction_result()
    end
  end

  defp create_stage(command, manifest_digest, options) do
    now = DateTime.utc_now()
    rows = Enum.sort_by(command["rows"], &{&1["principal_id"], &1["discord_user_id"]})

    lock_bindings(Enum.map(rows, &{&1["principal_id"], &1["discord_user_id"]}))

    execution =
      %AssignmentStageExecution{}
      |> AssignmentStageExecution.changeset(%{
        capture_id: command["capture_id"],
        manifest_digest: manifest_digest,
        preparer_principal_id: command["preparer_principal_id"],
        tool_revision: options.tool_revision,
        executed_at: now
      })
      |> Repo.insert!()

    Enum.each(rows, &stage_row(&1, execution, command["preparer_principal_id"], options))

    stage_receipt(execution)
  end

  defp stage_row(row, execution, preparer_id, options) do
    principal_id = row["principal_id"]
    subject = row["discord_user_id"]
    fingerprint = subject_fingerprint(subject, options.fingerprint_key)

    case binding_conflict(principal_id, subject) do
      nil ->
        assignment =
          %StagedAssignment{}
          |> StagedAssignment.proposal_changeset(%{
            principal_id: principal_id,
            capture_id: execution.capture_id,
            stage_execution_id: execution.id,
            provider: "discord",
            provider_subject: subject,
            username_snapshot: row["username_snapshot"],
            subject_fingerprint: fingerprint,
            proposal_digest: proposal_digest(execution.capture_id, row, options.fingerprint_key),
            state: "proposed",
            prepared_by_principal_id: preparer_id,
            tool_revision: options.tool_revision
          })
          |> Repo.insert!()

        insert_stage_result!(
          execution.id,
          principal_id,
          fingerprint,
          "proposed",
          assignment.id,
          nil
        )

      reason ->
        insert_stage_result!(execution.id, principal_id, fingerprint, "conflicted", nil, reason)
    end
  end

  defp apply_review(command, manifest_digest, options) do
    with :ok <- authorize_member_admin(command["reviewer_principal_id"]),
         {:ok, _capture} <- verified_capture(command["capture_id"]),
         :ok <- validate_unique_review_rows(command["rows"]) do
      Repo.transaction(fn ->
        lock_manifest!("review", manifest_digest)

        case Repo.get_by(AssignmentReviewExecution,
               capture_id: command["capture_id"],
               manifest_digest: manifest_digest
             ) do
          nil -> create_review(command, manifest_digest, options)
          execution -> review_receipt(execution)
        end
      end)
      |> transaction_result()
    end
  end

  defp create_review(command, manifest_digest, options) do
    assignments =
      command["rows"]
      |> Enum.map(& &1["assignment_id"])
      |> then(fn ids ->
        Repo.all(
          from(a in StagedAssignment,
            where: a.id in ^ids,
            order_by: [asc: a.id],
            lock: "FOR UPDATE"
          )
        )
      end)
      |> Map.new(&{&1.id, &1})

    lock_bindings(Enum.map(assignments, fn {_id, a} -> {a.principal_id, a.provider_subject} end))

    Enum.each(command["rows"], fn row ->
      assignment = Map.get(assignments, row["assignment_id"])
      validate_review_row!(assignment, row, command)

      if row["decision"] == "approve" do
        if reason =
             binding_conflict(assignment.principal_id, assignment.provider_subject, assignment.id),
           do: Repo.rollback({:conflicted, assignment.id, reason})
      end
    end)

    now = DateTime.utc_now()

    execution =
      %AssignmentReviewExecution{}
      |> AssignmentReviewExecution.changeset(%{
        capture_id: command["capture_id"],
        manifest_digest: manifest_digest,
        reviewer_principal_id: command["reviewer_principal_id"],
        tool_revision: options.tool_revision,
        executed_at: now
      })
      |> Repo.insert!()

    Enum.each(command["rows"], fn row ->
      assignment = Map.fetch!(assignments, row["assignment_id"])

      attrs =
        if row["decision"] == "approve" do
          %{
            state: "approved",
            approved_by_principal_id: command["reviewer_principal_id"],
            review_execution_id: execution.id,
            approved_at: now
          }
        else
          %{
            state: "rejected",
            review_execution_id: execution.id,
            terminal_at: now,
            terminal_actor_principal_id: command["reviewer_principal_id"],
            reason_code: "review_rejected"
          }
        end

      assignment |> StagedAssignment.transition_changeset(attrs) |> Repo.update!()
    end)

    review_receipt(execution)
  end

  defp withdraw_locked(command) do
    assignment =
      Repo.one(
        from(a in StagedAssignment,
          where: a.id == ^command["assignment_id"],
          lock: "FOR UPDATE"
        )
      )

    if is_nil(assignment) or assignment.proposal_digest != command["proposal_digest"] or
         assignment.state not in @active_states do
      Repo.rollback(:stale_assignment)
    end

    lock_bindings([{assignment.principal_id, assignment.provider_subject}])

    assignment
    |> StagedAssignment.transition_changeset(%{
      state: "withdrawn",
      terminal_at: DateTime.utc_now(),
      terminal_actor_principal_id: command["actor_principal_id"],
      reason_code: command["reason_code"]
    })
    |> Repo.update!()
    |> safe_assignment()
  end

  defp supersede(command, manifest_digest, package, options) do
    row = command["row"]

    with :ok <- validate_stage_rows([row], package),
         {:ok, _capture} <- verified_capture(command["capture_id"]) do
      Repo.transaction(fn ->
        lock_manifest!("stage", manifest_digest)

        existing_execution =
          Repo.get_by(AssignmentStageExecution,
            capture_id: command["capture_id"],
            manifest_digest: manifest_digest
          )

        if existing_execution,
          do: Repo.rollback({:replayed, supersede_receipt(existing_execution)})

        old =
          Repo.one(
            from(a in StagedAssignment,
              where: a.id == ^command["assignment_id"],
              lock: "FOR UPDATE"
            )
          )

        if is_nil(old) or old.proposal_digest != command["proposal_digest"] or
             old.state not in @active_states do
          Repo.rollback(:stale_assignment)
        end

        new_id = Ecto.UUID.generate()

        lock_bindings([
          {old.principal_id, old.provider_subject},
          {row["principal_id"], row["discord_user_id"]}
        ])

        old
        |> StagedAssignment.transition_changeset(%{
          state: "superseded",
          terminal_at: DateTime.utc_now(),
          terminal_actor_principal_id: command["actor_principal_id"],
          reason_code: "operator_correction",
          superseded_by_id: new_id
        })
        |> Repo.update!()

        if reason = binding_conflict(row["principal_id"], row["discord_user_id"]),
          do: Repo.rollback({:conflicted, reason})

        execution =
          %AssignmentStageExecution{}
          |> AssignmentStageExecution.changeset(%{
            capture_id: command["capture_id"],
            manifest_digest: manifest_digest,
            preparer_principal_id: command["actor_principal_id"],
            tool_revision: options.tool_revision,
            executed_at: DateTime.utc_now()
          })
          |> Repo.insert!()

        fingerprint = subject_fingerprint(row["discord_user_id"], options.fingerprint_key)

        assignment =
          %StagedAssignment{id: new_id}
          |> StagedAssignment.proposal_changeset(%{
            principal_id: row["principal_id"],
            capture_id: command["capture_id"],
            stage_execution_id: execution.id,
            provider_subject: row["discord_user_id"],
            username_snapshot: row["username_snapshot"],
            subject_fingerprint: fingerprint,
            proposal_digest: proposal_digest(command["capture_id"], row, options.fingerprint_key),
            state: "proposed",
            prepared_by_principal_id: command["actor_principal_id"],
            tool_revision: options.tool_revision
          })
          |> Repo.insert!()

        insert_stage_result!(
          execution.id,
          assignment.principal_id,
          fingerprint,
          "proposed",
          assignment.id,
          nil
        )

        supersede_receipt(execution)
      end)
      |> case do
        {:error, {:replayed, result}} -> {:ok, result}
        result -> transaction_result(result)
      end
    end
  end

  defp verified_capture(capture_id) do
    receipt =
      Repo.one(
        from(c in RosterReceipt,
          join: p in RosterReceipt,
          on: p.id == c.preflight_receipt_id,
          where:
            c.id == ^capture_id and c.kind == :capture and c.status == :succeeded and
              p.kind == :preflight and p.status == :succeeded and p.guild_id == c.guild_id and
              p.bot_application_id == c.bot_application_id,
          select: c
        )
      )

    if receipt, do: {:ok, receipt}, else: {:error, :invalid_capture}
  end

  defp validate_package(capture_id, package) do
    with {:ok, receipt} <- verified_capture(capture_id) do
      users = package["users"]

      cond do
        package["version"] != 1 ->
          {:error, :capture_package_version_mismatch}

        package["capture_id"] != capture_id ->
          {:error, :capture_package_id_mismatch}

        package["guild_id"] != receipt.guild_id ->
          {:error, :capture_package_guild_mismatch}

        package["tool_revision"] != receipt.tool_revision ->
          {:error, :capture_package_revision_mismatch}

        package["record_count"] != receipt.record_count ->
          {:error, :capture_package_count_mismatch}

        not is_list(users) or length(users) != receipt.record_count ->
          {:error, :capture_package_count_mismatch}

        RosterDigest.digest(users) != package["digest"] ->
          {:error, :capture_package_digest_mismatch}

        package["digest"] != receipt.package_digest ->
          {:error, :capture_receipt_digest_mismatch}

        true ->
          :ok
      end
    end
  end

  defp validate_stage_rows(rows, package) when is_list(rows) and rows != [] do
    users = Map.new(package["users"], &{&1["id"], &1["username"]})

    cond do
      Enum.any?(
        rows,
        &(MapSet.new(Map.keys(&1)) !=
              MapSet.new(~w(principal_id discord_user_id username_snapshot)))
      ) ->
        {:error, :invalid_stage_manifest}

      Enum.any?(rows, &(valid_uuid(&1["principal_id"]) != :ok)) ->
        {:error, :invalid_stage_manifest}

      Enum.any?(rows, fn row ->
        Map.get(users, row["discord_user_id"]) != row["username_snapshot"]
      end) ->
        {:error, :row_not_in_capture}

      duplicates?(rows, "principal_id") or duplicates?(rows, "discord_user_id") ->
        {:error, :duplicate_stage_mapping}

      true ->
        :ok
    end
  end

  defp validate_stage_rows(_, _), do: {:error, :invalid_stage_manifest}

  defp validate_review_row!(nil, _row, _command), do: Repo.rollback(:stale_review_manifest)

  defp validate_review_row!(assignment, row, command) do
    if assignment.capture_id != command["capture_id"] or assignment.state != "proposed" or
         assignment.proposal_digest != row["proposal_digest"] or
         assignment.prepared_by_principal_id == command["reviewer_principal_id"] do
      Repo.rollback(:stale_or_unreviewable_proposal)
    end
  end

  defp validate_unique_review_rows(rows) do
    if is_list(rows) and rows != [] and not duplicates?(rows, "assignment_id"),
      do: :ok,
      else: {:error, :invalid_review_manifest}
  end

  defp binding_conflict(principal_id, subject, except_assignment_id \\ nil) do
    assignment_conflict_query =
      from(a in StagedAssignment,
        where:
          a.state in ^@active_states and
            (a.principal_id == ^principal_id or a.provider_subject == ^subject)
      )

    assignment_conflict_query =
      if except_assignment_id,
        do: where(assignment_conflict_query, [a], a.id != ^except_assignment_id),
        else: assignment_conflict_query

    cond do
      not member_principal?(principal_id) ->
        "invalid_member_principal_relationship"

      Repo.exists?(
        from(e in ExternalIdentity,
          where:
            e.provider == "discord" and
                (e.principal_id == ^principal_id or e.provider_subject == ^subject)
        )
      ) ->
        "permanent_identity_collision"

      Repo.exists?(
        from(c in InvitationAcceptanceDiscordSubjectClaim,
          where: c.provider == "discord" and c.provider_subject == ^subject
        )
      ) ->
        "active_claim_collision"

      Repo.exists?(assignment_conflict_query) ->
        "active_assignment_collision"

      true ->
        nil
    end
  end

  defp member_principal?(principal_id) do
    Repo.exists?(
      from(p in Principal,
        join: u in "user_profiles",
        on: u.principal_id == p.id,
        join: m in "member_profiles",
        on: m.id == p.id and m.user_profile_id == u.id,
        where: p.id == ^principal_id
      )
    )
  end

  defp authorize_member_admin(principal_id) do
    if Repo.exists?(
         from(r in UserRole,
           where: r.principal_id == ^principal_id and r.role in ^@member_admin_roles
         )
       ),
       do: :ok,
       else: {:error, :unauthorized_principal}
  end

  defp exact_stage_command(command),
    do:
      exact_command(
        command,
        ~w(version capture_id preparer_principal_id rows),
        1,
        valid_uuid(command["capture_id"]) == :ok and
          valid_uuid(command["preparer_principal_id"]) == :ok and is_list(command["rows"])
      )

  defp exact_review_command(command) do
    with :ok <-
           exact_command(
             command,
             ~w(version capture_id reviewer_principal_id rows),
             1,
             valid_uuid(command["capture_id"]) == :ok and
               valid_uuid(command["reviewer_principal_id"]) == :ok and is_list(command["rows"])
           ),
         true <-
           Enum.all?(command["rows"], fn row ->
             MapSet.new(Map.keys(row)) == MapSet.new(~w(assignment_id proposal_digest decision)) and
               row["decision"] in ~w(approve reject) and valid_uuid(row["assignment_id"]) == :ok
           end) do
      :ok
    else
      _ -> {:error, :invalid_review_manifest}
    end
  end

  defp exact_withdraw_command(command),
    do:
      exact_command(
        command,
        ~w(version action assignment_id proposal_digest actor_principal_id reason_code),
        1,
        command["action"] == "withdraw" and valid_uuid(command["assignment_id"]) == :ok and
          valid_uuid(command["actor_principal_id"]) == :ok and
          command["reason_code"] in ~w(operator_correction operator_withdrawal)
      )

  defp exact_supersede_command(command) do
    exact_command(
      command,
      ~w(version action capture_id assignment_id proposal_digest actor_principal_id row),
      1,
      command["action"] == "supersede" and valid_uuid(command["capture_id"]) == :ok and
        valid_uuid(command["assignment_id"]) == :ok and
        valid_uuid(command["actor_principal_id"]) == :ok and
        is_map(command["row"])
    )
  end

  defp exact_command(command, keys, version, condition) do
    if MapSet.new(Map.keys(command)) == MapSet.new(keys) and command["version"] == version and
         condition,
       do: :ok,
       else: {:error, :invalid_manifest}
  end

  defp valid_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_uuid}
    end
  end

  defp duplicates?(rows, key) do
    values = Enum.map(rows, & &1[key])
    length(values) != MapSet.size(MapSet.new(values))
  end

  defp insert_stage_result!(
         execution_id,
         principal_id,
         fingerprint,
         outcome,
         assignment_id,
         reason
       ) do
    %AssignmentStageResult{}
    |> AssignmentStageResult.changeset(%{
      stage_execution_id: execution_id,
      principal_id: principal_id,
      subject_fingerprint: fingerprint,
      outcome: outcome,
      assignment_id: assignment_id,
      reason_code: reason
    })
    |> Repo.insert!()
  end

  defp stage_receipt(execution) do
    rows =
      Repo.all(from(r in AssignmentStageResult, where: r.stage_execution_id == ^execution.id))

    %{
      execution_id: execution.id,
      capture_id: execution.capture_id,
      counts: Enum.frequencies_by(rows, & &1.outcome),
      rows:
        Enum.map(rows, fn row ->
          %{
            assignment_id: row.assignment_id,
            principal_id: row.principal_id,
            subject_fingerprint: row.subject_fingerprint,
            state: row.outcome,
            reason_code: row.reason_code
          }
        end)
    }
  end

  defp review_receipt(execution) do
    assignments =
      Repo.all(from(a in StagedAssignment, where: a.review_execution_id == ^execution.id))

    %{
      execution_id: execution.id,
      capture_id: execution.capture_id,
      counts: Enum.frequencies_by(assignments, & &1.state),
      rows: Enum.map(assignments, &safe_assignment/1)
    }
  end

  defp supersede_receipt(execution) do
    replacement =
      Repo.one!(
        from(a in StagedAssignment,
          where: a.stage_execution_id == ^execution.id
        )
      )

    old = Repo.get_by!(StagedAssignment, superseded_by_id: replacement.id)

    %{
      superseded_assignment_id: old.id,
      replacement: safe_assignment(replacement)
    }
  end

  defp safe_assignment(assignment) do
    %{
      assignment_id: assignment.id,
      principal_id: assignment.principal_id,
      subject_fingerprint: assignment.subject_fingerprint,
      state: assignment.state
    }
  end

  defp proposal_digest(capture_id, row, key) do
    fingerprint(
      Jason.encode!(%{
        capture_id: capture_id,
        principal_id: row["principal_id"],
        discord_user_id: row["discord_user_id"],
        username_snapshot: row["username_snapshot"]
      }),
      key
    )
  end

  defp subject_fingerprint(subject, key), do: fingerprint("discord:" <> subject, key)

  defp fingerprint(value, key),
    do: :crypto.mac(:hmac, :sha256, key, value) |> Base.encode16(case: :lower)

  defp lock_manifest!(kind, digest) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["discord:#{kind}:#{digest}"],
      log: false
    )
  end

  defp lock_bindings(bindings) do
    bindings
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&DiscordSubjectLock.lock_principal!/1)

    bindings
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&DiscordSubjectLock.lock!/1)
  end

  defp report_row(fingerprint, assignments, conflicts) do
    case Enum.max_by(assignments, & &1.created_at, DateTime, fn -> nil end) do
      nil -> conflict_or_omitted_report_row(fingerprint, conflicts)
      assignment -> assignment_report_row(assignment)
    end
  end

  defp assignment_report_row(assignment) do
    %{
      assignment_id: assignment.id,
      principal_id: assignment.principal_id,
      subject_fingerprint: assignment.subject_fingerprint,
      outcome: report_outcome(assignment.state)
    }
  end

  defp conflict_or_omitted_report_row(fingerprint, conflicts) do
    case Enum.max_by(conflicts, & &1.created_at, DateTime, fn -> nil end) do
      nil ->
        %{subject_fingerprint: fingerprint, outcome: "omitted"}

      conflict ->
        %{
          assignment_id: nil,
          principal_id: conflict.principal_id,
          subject_fingerprint: fingerprint,
          outcome: "conflicted",
          reason_code: conflict.reason_code
        }
    end
  end

  defp report_outcome("proposed"), do: "unresolved"
  defp report_outcome(state) when state in ~w(approved rejected promoted), do: state
  defp report_outcome(state) when state in ~w(withdrawn superseded), do: "omitted"

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
