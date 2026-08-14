defmodule Dhc.Discord.IdentityRecoveryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth.{DiscordSubjectLock, ExternalIdentity, Principal, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityBindingHistory,
    IdentityRecovery,
    IdentityRecoveryApproval,
    IdentityRecoveryAuditEvent,
    IdentityRecoveryCase,
    IdentityRecoveryProof,
    SignedManifest
  }

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  @manifest_key "ale-221-concurrency-manifest-key"
  @fingerprint_key "ale-221-concurrency-fingerprint-key"

  test "recovery and a concurrent permanent binding serialize and fail closed" do
    test_process = self()
    task_supervisor = start_supervised!(Task.Supervisor)
    fixture = unboxed(&ready_recovery_fixture/0)

    on_exit(fn -> unboxed(fn -> delete_fixture(fixture) end) end)

    binder =
      database_task(task_supervisor, test_process, :binding, fn ->
        Repo.transaction(fn ->
          DiscordSubjectLock.lock_principal!(fixture.destination_id)
          DiscordSubjectLock.lock!(fixture.incoming_subject)
          send(test_process, {:binding_locked, self()})

          receive do
            :commit_binding ->
              destination = Repo.get!(Principal, fixture.destination_id)

              %ExternalIdentity{}
              |> ExternalIdentity.create_changeset(destination, %{
                provider: "discord",
                provider_subject: fixture.incoming_subject,
                metadata: %{}
              })
              |> Repo.insert!()
          end
        end)
      end)

    assert_receive {:database_backend, :binding, _backend_pid}
    assert_receive {:binding_locked, binder_pid}
    assert binder_pid == binder.pid

    completion =
      database_task(task_supervisor, test_process, :completion, fn ->
        IdentityRecovery.complete(fixture.case_reference, @fingerprint_key)
      end)

    assert_receive {:database_backend, :completion, completion_backend_pid}
    assert_backend_waiting_on_lock(completion_backend_pid)

    send(binder.pid, :commit_binding)
    assert {:ok, %ExternalIdentity{}} = Task.await(binder)
    assert {:error, :invalid_recovery_command} = Task.await(completion)

    unboxed(fn ->
      source = Repo.get!(ExternalIdentity, fixture.source_identity_id)
      assert is_nil(source.retired_at)
      assert source.sign_in_disabled_at

      recovery_case = Repo.get!(IdentityRecoveryCase, fixture.recovery_case_id)
      assert recovery_case.state == "open"
      assert Repo.aggregate(IdentityBindingHistory, :count) == 0

      assert Repo.exists?(
               from(identity in ExternalIdentity,
                 where:
                   identity.principal_id == ^fixture.destination_id and
                     identity.provider_subject == ^fixture.incoming_subject and
                     is_nil(identity.retired_at)
               )
             )
    end)
  end

  defp ready_recovery_fixture do
    source = Dhc.MemberFixtures.member_fixture()
    destination = Dhc.MemberFixtures.member_fixture()
    first_approver = Dhc.MemberFixtures.member_fixture()
    second_approver = Dhc.MemberFixtures.member_fixture()

    Repo.insert!(%UserRole{principal_id: first_approver.principal_id, role: "admin"})
    Repo.insert!(%UserRole{principal_id: second_approver.principal_id, role: "president"})

    source_subject = "concurrent-source-#{System.unique_integer([:positive])}"
    incoming_subject = "concurrent-incoming-#{System.unique_integer([:positive])}"
    source_principal = Repo.get!(Principal, source.principal_id)

    source_identity =
      %ExternalIdentity{}
      |> ExternalIdentity.create_changeset(source_principal, %{
        provider: "discord",
        provider_subject: source_subject,
        metadata: %{}
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    open_command = %{
      "version" => 1,
      "action" => "open",
      "issued_at" => DateTime.to_iso8601(now),
      "binding_id" => source_identity.id,
      "binding_fingerprint" => fingerprint(source_subject),
      "reporter_reference" => "concurrency-test",
      "reason_code" => "replacement_request",
      "evidence_references" => ["concurrency-evidence"],
      "actor_principal_id" => first_approver.principal_id
    }

    assert {:ok, receipt} =
             IdentityRecovery.open_signed(SignedManifest.sign(open_command, @manifest_key), %{
               manifest_key: @manifest_key,
               fingerprint_key: @fingerprint_key,
               now: now
             })

    assert {:ok, ^receipt} =
             IdentityRecovery.record_discord_oauth_proof(
               receipt.case_reference,
               %{"sub" => incoming_subject},
               @fingerprint_key
             )

    destination_principal = Repo.get!(Principal, destination.principal_id)
    {magic_link, token_row} = PrincipalToken.build_magic_link_token(destination_principal)
    Repo.insert!(token_row)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(receipt.case_reference, magic_link)

    approve!(first_approver.principal_id, destination.principal_id, incoming_subject, receipt)
    approve!(second_approver.principal_id, destination.principal_id, incoming_subject, receipt)

    recovery_case = Repo.get_by!(IdentityRecoveryCase, case_reference: receipt.case_reference)

    %{
      case_reference: receipt.case_reference,
      recovery_case_id: recovery_case.id,
      source_identity_id: source_identity.id,
      destination_id: destination.principal_id,
      incoming_subject: incoming_subject,
      principal_ids: [
        source.principal_id,
        destination.principal_id,
        first_approver.principal_id,
        second_approver.principal_id
      ]
    }
  end

  defp approve!(actor_id, destination_id, incoming_subject, receipt) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    command = %{
      "version" => 1,
      "action" => "approve",
      "issued_at" => DateTime.to_iso8601(now),
      "case_reference" => receipt.case_reference,
      "source_binding_fingerprint" => receipt.binding_fingerprint,
      "destination_principal_id" => destination_id,
      "incoming_subject_fingerprint" => fingerprint(incoming_subject),
      "evidence_references" => receipt.evidence_references,
      "operation" => "replacement",
      "actor_principal_id" => actor_id
    }

    assert {:ok, _receipt} =
             IdentityRecovery.approve_signed(SignedManifest.sign(command, @manifest_key), %{
               manifest_key: @manifest_key,
               now: now
             })
  end

  defp database_task(task_supervisor, test_process, label, fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(test_process, {:database_backend, label, backend_pid})
        fun.()
      end)
    end)
  end

  defp assert_backend_waiting_on_lock(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_assert_backend_waiting_on_lock(backend_pid, deadline)
  end

  defp do_assert_backend_waiting_on_lock(backend_pid, deadline) do
    waiting? =
      unboxed(fn ->
        case Repo.query!(
               "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [["Lock"]] -> true
          _rows -> false
        end
      end)

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_backend_waiting_on_lock(backend_pid, deadline)

      true ->
        flunk("database backend #{backend_pid} did not wait on a Discord binding lock")
    end
  end

  defp delete_fixture(fixture) do
    recovery_history_triggers(:disable)

    try do
      case_id = fixture.recovery_case_id
      principal_ids = fixture.principal_ids

      Repo.delete_all(
        from(history in IdentityBindingHistory, where: history.recovery_case_id == ^case_id)
      )

      Repo.delete_all(
        from(audit in IdentityRecoveryAuditEvent, where: audit.recovery_case_id == ^case_id)
      )

      Repo.delete_all(
        from(approval in IdentityRecoveryApproval, where: approval.recovery_case_id == ^case_id)
      )

      Repo.delete_all(
        from(proof in IdentityRecoveryProof, where: proof.recovery_case_id == ^case_id)
      )

      Repo.delete_all(
        from(recovery_case in IdentityRecoveryCase, where: recovery_case.id == ^case_id)
      )

      Repo.delete_all(from(token in PrincipalToken, where: token.principal_id in ^principal_ids))

      Repo.delete_all(
        from(identity in ExternalIdentity, where: identity.principal_id in ^principal_ids)
      )

      Repo.delete_all(from(role in UserRole, where: role.principal_id in ^principal_ids))

      profile_ids =
        Repo.all(
          from(profile in UserProfile,
            where: profile.principal_id in ^principal_ids,
            select: profile.id
          )
        )

      Repo.delete_all(
        from(member in MemberProfile, where: member.user_profile_id in ^profile_ids)
      )

      Repo.delete_all(from(profile in UserProfile, where: profile.id in ^profile_ids))
      Repo.delete_all(from(principal in Principal, where: principal.id in ^principal_ids))
    after
      recovery_history_triggers(:enable)
    end
  end

  defp recovery_history_triggers(action) when action in [:disable, :enable] do
    sql_action = action |> Atom.to_string() |> String.upcase()

    for {table, trigger} <- [
          {"discord_identity_recovery_audit_events", "ale220_reject_recovery_audit_mutation"},
          {"discord_identity_recovery_proofs",
           "ale221_reject_discord_identity_recovery_proofs_mutation"},
          {"discord_identity_recovery_approvals",
           "ale221_reject_discord_identity_recovery_approvals_mutation"},
          {"discord_identity_binding_history",
           "ale221_reject_discord_identity_binding_history_mutation"}
        ] do
      Repo.query!("ALTER TABLE #{table} #{sql_action} TRIGGER #{trigger}")
    end
  end

  defp fingerprint(subject),
    do:
      :crypto.mac(:hmac, :sha256, @fingerprint_key, subject)
      |> Base.encode16(case: :lower)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
