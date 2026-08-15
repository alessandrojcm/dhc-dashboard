defmodule Dhc.Discord.Assignments do
  @moduledoc """
  Controlled staging and independent review of existing-Member Discord assignments.

  All binding decisions use Principal UUIDs and immutable Discord subjects from
  one validated, out-of-band roster export. Names and email addresses are never
  selectors. The roster is not persisted by the application.
  """

  import Ecto.Query

  alias Dhc.Auth.{DiscordSubjectLock, ExternalIdentity, Principal, UserRole}

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    AssignmentStageResult,
    StagedAssignment,
    StagedAssignmentAuditEvent
  }

  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo

  @member_admin_roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)
  @active_states ~w(proposed approved)
  @roster_keys MapSet.new(~w(id username global_name nickname))
  @stage_row_keys MapSet.new(~w(principal_id discord_user_id username_snapshot))
  @review_row_keys MapSet.new(~w(assignment_id decision))

  def stage(roster, rows, preparer_principal_id, options) do
    capture_id = Ecto.UUID.generate()

    with :ok <- validate_roster(roster),
         :ok <- valid_uuid(preparer_principal_id),
         :ok <- validate_stage_rows(rows, roster) do
      Repo.transaction(fn ->
        bindings = Enum.map(rows, &{&1["principal_id"], &1["discord_user_id"]})
        lock_operation(bindings, [preparer_principal_id])
        authorize_member_admin_locked!(preparer_principal_id)
        validate_principals_locked!(Enum.map(rows, & &1["principal_id"]))
        create_stage(capture_id, rows, preparer_principal_id, options)
      end)
      |> transaction_result()
    end
  end

  def review_evidence(capture_id, roster, reviewer_principal_id) do
    with :ok <- valid_uuid(capture_id),
         :ok <- valid_uuid(reviewer_principal_id),
         :ok <- validate_roster(roster),
         :ok <- capture_exists(capture_id) do
      Repo.transaction(fn ->
        lock_operation([], [reviewer_principal_id])
        authorize_member_admin_locked!(reviewer_principal_id)

        assignments =
          Repo.all(
            from(a in StagedAssignment,
              where: a.capture_id == ^capture_id and a.state == "proposed",
              order_by: [asc: a.id]
            )
          )

        if Enum.any?(assignments, &(&1.prepared_by_principal_id == reviewer_principal_id)) do
          Repo.rollback(:reviewer_must_differ_from_preparer)
        end

        users = Map.new(roster, &{&1["id"], &1})

        Enum.map(assignments, fn assignment ->
          user =
            Map.get(users, assignment.provider_subject) ||
              Repo.rollback(:assignment_not_in_roster)

          if user["username"] != assignment.username_snapshot do
            Repo.rollback(:assignment_roster_mismatch)
          end

          %{
            assignment_id: assignment.id,
            principal_id: assignment.principal_id,
            discord_user_id: assignment.provider_subject,
            username_snapshot: assignment.username_snapshot,
            global_name: user["global_name"],
            nickname: user["nickname"],
            capture_id: assignment.capture_id
          }
        end)
      end)
      |> transaction_result()
    end
  end

  def apply_review(capture_id, rows, reviewer_principal_id, options) do
    with :ok <- valid_uuid(capture_id),
         :ok <- valid_uuid(reviewer_principal_id),
         :ok <- validate_review_rows(rows),
         :ok <- capture_exists(capture_id) do
      Repo.transaction(fn ->
        create_review(capture_id, rows, reviewer_principal_id, options)
      end)
      |> transaction_result()
    end
  end

  def withdraw(assignment_id, actor_principal_id, reason_code) do
    with :ok <- valid_uuid(assignment_id),
         :ok <- valid_uuid(actor_principal_id),
         true <- reason_code in ~w(operator_correction operator_withdrawal) do
      Repo.transaction(fn ->
        withdraw_locked(assignment_id, actor_principal_id, reason_code)
      end)
      |> transaction_result()
    else
      false -> {:error, :invalid_withdrawal}
      error -> error
    end
  end

  def supersede(assignment_id, roster, row, actor_principal_id, options) do
    capture_id = Ecto.UUID.generate()

    with :ok <- valid_uuid(assignment_id),
         :ok <- valid_uuid(actor_principal_id),
         :ok <- validate_roster(roster),
         :ok <- validate_stage_rows([row], roster) do
      Repo.transaction(fn ->
        supersede_locked(assignment_id, capture_id, row, actor_principal_id, options)
      end)
      |> transaction_result()
    end
  end

  def report(capture_id, roster, options) do
    with :ok <- valid_uuid(capture_id),
         :ok <- validate_roster(roster),
         :ok <- capture_exists(capture_id) do
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
        Enum.map(roster, fn user ->
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
          "captured" => length(roster),
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

  defp create_stage(capture_id, rows, preparer_principal_id, options) do
    execution =
      %AssignmentStageExecution{}
      |> AssignmentStageExecution.changeset(%{
        capture_id: capture_id,
        preparer_principal_id: preparer_principal_id,
        tool_revision: options.tool_revision,
        executed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    rows
    |> Enum.sort_by(&{&1["principal_id"], &1["discord_user_id"]})
    |> Enum.each(&stage_row(&1, execution, preparer_principal_id, options))

    stage_result(execution)
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

  defp create_review(capture_id, rows, reviewer_principal_id, options) do
    assignment_keys = assignment_keys(rows)

    lock_operation(
      Enum.map(assignment_keys, &{&1.principal_id, &1.provider_subject}),
      [reviewer_principal_id]
    )

    authorize_member_admin_locked!(reviewer_principal_id)

    assignments =
      rows
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

    Enum.each(rows, fn row ->
      assignment = Map.get(assignments, row["assignment_id"])
      validate_review_row!(assignment, capture_id, reviewer_principal_id)

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
        capture_id: capture_id,
        reviewer_principal_id: reviewer_principal_id,
        tool_revision: options.tool_revision,
        executed_at: now
      })
      |> Repo.insert!()

    Enum.each(rows, fn row ->
      assignment = Map.fetch!(assignments, row["assignment_id"])

      attrs =
        if row["decision"] == "approve" do
          %{
            state: "approved",
            approved_by_principal_id: reviewer_principal_id,
            review_execution_id: execution.id,
            approved_at: now
          }
        else
          %{
            state: "rejected",
            review_execution_id: execution.id,
            terminal_at: now,
            terminal_actor_principal_id: reviewer_principal_id,
            reason_code: "review_rejected"
          }
        end

      assignment |> StagedAssignment.transition_changeset(attrs) |> Repo.update!()
    end)

    review_result(execution)
  end

  defp withdraw_locked(assignment_id, actor_principal_id, reason_code) do
    assignment_key = Repo.get(StagedAssignment, assignment_id)

    if is_nil(assignment_key), do: Repo.rollback(:stale_assignment)

    lock_operation(
      [{assignment_key.principal_id, assignment_key.provider_subject}],
      [actor_principal_id]
    )

    authorize_member_admin_locked!(actor_principal_id)
    assignment = assignment_for_update(assignment_id)

    if is_nil(assignment) or assignment.state not in @active_states do
      Repo.rollback(:stale_assignment)
    end

    assignment
    |> StagedAssignment.transition_changeset(%{
      state: "withdrawn",
      terminal_at: DateTime.utc_now(),
      terminal_actor_principal_id: actor_principal_id,
      reason_code: reason_code
    })
    |> Repo.update!()
    |> safe_assignment()
  end

  defp supersede_locked(assignment_id, capture_id, row, actor_principal_id, options) do
    old_key = Repo.get(StagedAssignment, assignment_id)

    if is_nil(old_key), do: Repo.rollback(:stale_assignment)

    lock_operation(
      [
        {old_key.principal_id, old_key.provider_subject},
        {row["principal_id"], row["discord_user_id"]}
      ],
      [actor_principal_id]
    )

    authorize_member_admin_locked!(actor_principal_id)
    validate_principals_locked!([row["principal_id"]])
    old = assignment_for_update(assignment_id)

    if is_nil(old) or old.state not in @active_states do
      Repo.rollback(:stale_assignment)
    end

    new_id = Ecto.UUID.generate()

    old
    |> StagedAssignment.transition_changeset(%{
      state: "superseded",
      terminal_at: DateTime.utc_now(),
      terminal_actor_principal_id: actor_principal_id,
      reason_code: "operator_correction",
      superseded_by_id: new_id
    })
    |> Repo.update!()

    if reason = binding_conflict(row["principal_id"], row["discord_user_id"]),
      do: Repo.rollback({:conflicted, reason})

    execution =
      %AssignmentStageExecution{}
      |> AssignmentStageExecution.changeset(%{
        capture_id: capture_id,
        preparer_principal_id: actor_principal_id,
        tool_revision: options.tool_revision,
        executed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    fingerprint = subject_fingerprint(row["discord_user_id"], options.fingerprint_key)

    replacement =
      %StagedAssignment{id: new_id}
      |> StagedAssignment.proposal_changeset(%{
        principal_id: row["principal_id"],
        capture_id: capture_id,
        stage_execution_id: execution.id,
        provider: "discord",
        provider_subject: row["discord_user_id"],
        username_snapshot: row["username_snapshot"],
        subject_fingerprint: fingerprint,
        state: "proposed",
        prepared_by_principal_id: actor_principal_id,
        tool_revision: options.tool_revision
      })
      |> Repo.insert!()

    insert_stage_result!(
      execution.id,
      replacement.principal_id,
      fingerprint,
      "proposed",
      replacement.id,
      nil
    )

    %{
      capture_id: capture_id,
      superseded_assignment_id: old.id,
      replacement: safe_assignment(replacement)
    }
  end

  defp capture_exists(capture_id) do
    if Repo.exists?(from(e in AssignmentStageExecution, where: e.capture_id == ^capture_id)),
      do: :ok,
      else: {:error, :invalid_capture}
  end

  defp validate_roster(roster) when is_list(roster) do
    cond do
      Enum.any?(roster, &(not valid_roster_member?(&1))) ->
        {:error, :invalid_roster}

      duplicates?(roster, "id") ->
        {:error, :duplicate_roster_member}

      true ->
        :ok
    end
  end

  defp validate_roster(_), do: {:error, :invalid_roster}

  defp valid_roster_member?(member) when is_map(member) do
    MapSet.new(Map.keys(member)) == @roster_keys and
      nonempty_string?(member["id"]) and
      nonempty_string?(member["username"]) and
      optional_string?(member["global_name"]) and
      optional_string?(member["nickname"])
  end

  defp valid_roster_member?(_), do: false

  defp validate_stage_rows(rows, roster) when is_list(rows) and rows != [] do
    users = Map.new(roster, &{&1["id"], &1["username"]})

    cond do
      Enum.any?(rows, &(not valid_stage_row?(&1))) ->
        {:error, :invalid_stage_rows}

      Enum.any?(rows, fn row ->
        Map.get(users, row["discord_user_id"]) != row["username_snapshot"]
      end) ->
        {:error, :row_not_in_roster}

      duplicates?(rows, "principal_id") or duplicates?(rows, "discord_user_id") ->
        {:error, :duplicate_stage_mapping}

      true ->
        :ok
    end
  end

  defp validate_stage_rows(_, _), do: {:error, :invalid_stage_rows}

  defp valid_stage_row?(row) when is_map(row) do
    MapSet.new(Map.keys(row)) == @stage_row_keys and
      valid_uuid(row["principal_id"]) == :ok and
      nonempty_string?(row["discord_user_id"]) and
      nonempty_string?(row["username_snapshot"])
  end

  defp valid_stage_row?(_), do: false

  defp validate_review_rows(rows) when is_list(rows) and rows != [] do
    if Enum.all?(rows, &valid_review_row?/1) and not duplicates?(rows, "assignment_id"),
      do: :ok,
      else: {:error, :invalid_review_rows}
  end

  defp validate_review_rows(_), do: {:error, :invalid_review_rows}

  defp valid_review_row?(row) when is_map(row) do
    MapSet.new(Map.keys(row)) == @review_row_keys and
      valid_uuid(row["assignment_id"]) == :ok and row["decision"] in ~w(approve reject)
  end

  defp valid_review_row?(_), do: false

  defp validate_review_row!(nil, _capture_id, _reviewer_principal_id),
    do: Repo.rollback(:stale_review)

  defp validate_review_row!(assignment, capture_id, reviewer_principal_id) do
    if assignment.capture_id != capture_id or assignment.state != "proposed" or
         assignment.prepared_by_principal_id == reviewer_principal_id do
      Repo.rollback(:stale_or_unreviewable_proposal)
    end
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
            e.provider == "discord" and is_nil(e.retired_at) and
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

  defp authorize_member_admin_locked!(principal_id) do
    role =
      Repo.one(
        from(r in UserRole,
          where: r.principal_id == ^principal_id and r.role in ^@member_admin_roles,
          order_by: [asc: r.id],
          limit: 1
        )
      )

    if is_nil(role), do: Repo.rollback(:unauthorized_principal)
    :ok
  end

  defp validate_principals_locked!(principal_ids) do
    expected = principal_ids |> Enum.uniq() |> Enum.sort()

    found =
      Repo.all(
        from(p in Principal,
          where: p.id in ^expected,
          select: p.id,
          order_by: [asc: p.id],
          lock: "FOR KEY SHARE"
        )
      )

    if found != expected, do: Repo.rollback(:unknown_principal)
  end

  defp valid_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_uuid}
    end
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""
  defp optional_string?(value), do: is_nil(value) or is_binary(value)

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

  defp stage_result(execution) do
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

  defp review_result(execution) do
    rows =
      Repo.all(
        from(e in StagedAssignmentAuditEvent,
          join: a in StagedAssignment,
          on: a.id == e.assignment_id,
          where:
            e.review_execution_id == ^execution.id and
              e.new_state in ["approved", "rejected"],
          order_by: [asc: e.assignment_id],
          select: {a, e.new_state}
        )
      )

    %{
      execution_id: execution.id,
      capture_id: execution.capture_id,
      counts: Enum.frequencies_by(rows, &elem(&1, 1)),
      rows: Enum.map(rows, fn {assignment, state} -> safe_assignment(assignment, state) end)
    }
  end

  defp safe_assignment(assignment), do: safe_assignment(assignment, assignment.state)

  defp safe_assignment(assignment, state) do
    %{
      assignment_id: assignment.id,
      principal_id: assignment.principal_id,
      subject_fingerprint: assignment.subject_fingerprint,
      state: state
    }
  end

  defp subject_fingerprint(subject, key),
    do: Dhc.Discord.SubjectFingerprint.generate(subject, key)

  defp assignment_keys(rows) do
    ids = Enum.map(rows, & &1["assignment_id"])

    Repo.all(
      from(a in StagedAssignment,
        where: a.id in ^ids,
        select: %{id: a.id, principal_id: a.principal_id, provider_subject: a.provider_subject}
      )
    )
  end

  defp assignment_for_update(id) do
    Repo.one(from(a in StagedAssignment, where: a.id == ^id, lock: "FOR UPDATE"))
  end

  defp lock_operation(bindings, actor_principal_ids) do
    (actor_principal_ids ++ Enum.map(bindings, &elem(&1, 0)))
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
