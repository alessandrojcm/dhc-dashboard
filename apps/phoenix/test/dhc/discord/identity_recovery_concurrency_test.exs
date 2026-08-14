defmodule Dhc.Discord.IdentityRecoveryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{DiscordSubjectLock, ExternalIdentity, Principal, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityRecovery,
    IdentityRecoveryCase,
    SignedManifest,
    SubjectFingerprint
  }

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  @manifest_key "ale-220-concurrency-manifest-key"
  @operator_proof_key "ale-220-concurrency-operator-proof-key"
  @fingerprint_key "ale-220-concurrency-fingerprint-key"

  setup do
    fixture = unboxed(&containment_fixture/0)
    on_exit(fn -> unboxed(fn -> delete_fixture(fixture) end) end)
    %{fixture: fixture, task_supervisor: start_supervised!(Task.Supervisor)}
  end

  test "containment wins before a waiting Discord sign-in and no Session can escape",
       %{fixture: fixture, task_supervisor: task_supervisor} do
    test_process = self()
    role_locker = lock_operator_role(task_supervisor, fixture, test_process)
    assert_receive {:operator_role_locked, role_locker_pid}
    assert role_locker_pid == role_locker.pid

    recovery =
      database_task(task_supervisor, test_process, :recovery, fn ->
        IdentityRecovery.open_signed(fixture.manifest, fixture.proof, fixture.options)
      end)

    assert_receive {:database_backend, :recovery, recovery_backend}
    assert_backend_waiting_on_lock(recovery_backend)

    sign_in =
      database_task(task_supervisor, test_process, :sign_in, fn ->
        Auth.sign_in_with_discord(%{"sub" => fixture.subject})
      end)

    assert_receive {:database_backend, :sign_in, sign_in_backend}
    assert_backend_waiting_on_lock(sign_in_backend)

    send(role_locker.pid, :release_role)
    assert {:ok, :released} = Task.await(role_locker)
    assert {:ok, _receipt} = Task.await(recovery)
    assert {:error, :invalid} = Task.await(sign_in)

    refute unboxed(fn ->
             Repo.exists?(
               from(token in PrincipalToken,
                 where:
                   token.principal_id == ^fixture.target.principal_id and
                     token.context == "session"
               )
             )
           end)
  end

  test "a sign-in that linearizes first is revoked before containment returns",
       %{fixture: fixture, task_supervisor: task_supervisor} do
    test_process = self()
    profile_locker = lock_profile(task_supervisor, fixture.target.profile_id, test_process)
    assert_receive {:profile_locked, profile_locker_pid}
    assert profile_locker_pid == profile_locker.pid

    sign_in =
      database_task(task_supervisor, test_process, :sign_in, fn ->
        Auth.sign_in_with_discord(%{"sub" => fixture.subject})
      end)

    assert_receive {:database_backend, :sign_in, sign_in_backend}
    assert_backend_waiting_on_lock(sign_in_backend)

    recovery =
      database_task(task_supervisor, test_process, :recovery, fn ->
        IdentityRecovery.open_signed(fixture.manifest, fixture.proof, fixture.options)
      end)

    assert_receive {:database_backend, :recovery, recovery_backend}
    assert_backend_waiting_on_lock(recovery_backend)

    send(profile_locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(profile_locker)
    assert {:ok, %{session_token: token}} = Task.await(sign_in)
    assert {:ok, _receipt} = Task.await(recovery)
    assert {:error, :invalid} = unboxed(fn -> Auth.get_principal_by_session_token(token) end)
  end

  test "operator-role revocation that linearizes first prevents containment",
       %{fixture: fixture, task_supervisor: task_supervisor} do
    test_process = self()

    revoker =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            role =
              UserRole
              |> where(
                [candidate],
                candidate.principal_id == ^fixture.operator.principal_id and
                  candidate.role == "admin"
              )
              |> lock("FOR UPDATE")
              |> Repo.one!()

            Repo.delete!(role)
            send(test_process, {:operator_role_deleted, self()})

            receive do
              :commit_role_revocation -> :revoked
            end
          end)
        end)
      end)

    assert_receive {:operator_role_deleted, revoker_pid}
    assert revoker_pid == revoker.pid

    recovery =
      database_task(task_supervisor, test_process, :recovery, fn ->
        IdentityRecovery.open_signed(fixture.manifest, fixture.proof, fixture.options)
      end)

    assert_receive {:database_backend, :recovery, recovery_backend}
    assert_backend_waiting_on_lock(recovery_backend)

    send(revoker.pid, :commit_role_revocation)
    assert {:ok, :revoked} = Task.await(revoker)
    assert {:error, :unauthorized_operator} = Task.await(recovery)

    assert is_nil(
             unboxed(fn ->
               Repo.get!(ExternalIdentity, fixture.identity.id).sign_in_disabled_at
             end)
           )
  end

  test "recovery and a concurrent permanent binding serialize and fail closed",
       %{task_supervisor: task_supervisor} do
    test_process = self()
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

  defp containment_fixture do
    target = Dhc.MemberFixtures.member_fixture(is_active: true)
    operator = Dhc.MemberFixtures.member_fixture(is_active: true)
    principal = Repo.get!(Principal, target.principal_id)
    subject = "ale-220-race-#{System.unique_integer([:positive])}"

    identity =
      %ExternalIdentity{}
      |> ExternalIdentity.create_changeset(principal, %{
        provider: "discord",
        provider_subject: subject,
        metadata: %{}
      })
      |> Repo.insert!()

    Repo.insert!(%UserRole{principal_id: operator.principal_id, role: "admin"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    command = open_command(identity, subject, operator.principal_id, now, "support-case:race")

    manifest =
      SignedManifest.sign(command, operator.principal_id, manifest_key(operator.principal_id))

    proof = operator_proof(manifest, operator.principal_id, now)

    %{
      target: target,
      operator: operator,
      identity: identity,
      subject: subject,
      manifest: manifest,
      proof: proof,
      options: options(now, operator.principal_id),
      principal_ids: [target.principal_id, operator.principal_id]
    }
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

    command =
      open_command(
        source_identity,
        source_subject,
        first_approver.principal_id,
        now,
        "support-case:concurrency"
      )

    manifest =
      SignedManifest.sign(
        command,
        first_approver.principal_id,
        manifest_key(first_approver.principal_id)
      )

    proof = operator_proof(manifest, first_approver.principal_id, now)

    assert {:ok, receipt} =
             IdentityRecovery.open_signed(
               manifest,
               proof,
               options(now, first_approver.principal_id)
             )

    assert {:ok, ^receipt} =
             IdentityRecovery.record_discord_oauth_proof(
               receipt.case_reference,
               %{"sub" => incoming_subject},
               @fingerprint_key
             )

    destination_principal = Repo.get!(Principal, destination.principal_id)
    recovery_case = Repo.get_by!(IdentityRecoveryCase, case_reference: receipt.case_reference)

    {magic_link, token_row} =
      PrincipalToken.build_identity_recovery_token(destination_principal, recovery_case.id)

    Repo.insert!(token_row)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(receipt.case_reference, magic_link)

    approve!(first_approver.principal_id, destination.principal_id, incoming_subject, receipt)
    approve!(second_approver.principal_id, destination.principal_id, incoming_subject, receipt)

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

  defp open_command(identity, subject, actor_id, now, reporter_reference) do
    %{
      "version" => 1,
      "action" => "open",
      "issued_at" => DateTime.to_iso8601(now),
      "binding_id" => identity.id,
      "binding_fingerprint" => fingerprint(subject),
      "reporter_reference" => reporter_reference,
      "reason_code" => "replacement_request",
      "evidence_references" => ["evidence:concurrency"],
      "actor_principal_id" => actor_id
    }
  end

  defp operator_proof(manifest, actor_id, now) do
    {:ok, _command, manifest_digest, ^actor_id} =
      SignedManifest.verify(manifest, %{actor_id => manifest_key(actor_id)})

    SignedManifest.sign(
      %{
        "version" => 1,
        "action" => "authorize_identity_recovery",
        "issued_at" => DateTime.to_iso8601(now),
        "manifest_digest" => manifest_digest,
        "actor_principal_id" => actor_id,
        "nonce" => Ecto.UUID.generate()
      },
      actor_id,
      operator_proof_key(actor_id)
    )
  end

  defp options(now, actor_id),
    do: %{
      manifest_keys: %{actor_id => manifest_key(actor_id)},
      operator_proof_keys: %{actor_id => operator_proof_key(actor_id)},
      fingerprint_key: @fingerprint_key,
      now: now
    }

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
      "operation" => "replacement"
    }

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:ok, _receipt} =
             IdentityRecovery.approve_signed(SignedManifest.sign_ed25519(command, private_key), %{
               approver_public_keys: %{actor_id => public_key},
               now: now
             })
  end

  defp lock_operator_role(task_supervisor, fixture, test_process) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          UserRole
          |> where(
            [role],
            role.principal_id == ^fixture.operator.principal_id and role.role == "admin"
          )
          |> lock("FOR UPDATE")
          |> Repo.one!()

          send(test_process, {:operator_role_locked, self()})

          receive do
            :release_role -> :released
          end
        end)
      end)
    end)
  end

  defp lock_profile(task_supervisor, profile_id, test_process) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          UserProfile
          |> where([profile], profile.id == ^profile_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

          send(test_process, {:profile_locked, self()})

          receive do
            :release_profile -> :released
          end
        end)
      end)
    end)
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
        flunk("database backend #{backend_pid} did not wait on the expected Postgres lock")
    end
  end

  defp delete_fixture(fixture) do
    disable_recovery_triggers()

    try do
      Repo.delete_all("discord_identity_binding_history")
      Repo.delete_all("discord_identity_recovery_approvals")
      Repo.delete_all("discord_identity_recovery_proofs")
      Repo.delete_all("discord_identity_recovery_operator_proof_uses")
      Repo.delete_all("discord_identity_recovery_audit_events")
      Repo.delete_all("discord_identity_recovery_cases")

      Repo.delete_all(
        from(token in PrincipalToken, where: token.principal_id in ^fixture.principal_ids)
      )

      Repo.delete_all(
        from(identity in ExternalIdentity,
          where: identity.principal_id in ^fixture.principal_ids
        )
      )

      Repo.delete_all(from(role in UserRole, where: role.principal_id in ^fixture.principal_ids))

      profile_ids =
        Repo.all(
          from(profile in UserProfile,
            where: profile.principal_id in ^fixture.principal_ids,
            select: profile.id
          )
        )

      Repo.delete_all(
        from(member in MemberProfile, where: member.user_profile_id in ^profile_ids)
      )

      Repo.delete_all(from(profile in UserProfile, where: profile.id in ^profile_ids))
      Repo.delete_all(from(principal in Principal, where: principal.id in ^fixture.principal_ids))
    after
      enable_recovery_triggers()
    end
  end

  defp disable_recovery_triggers do
    for table <- recovery_tables(), do: Repo.query!("ALTER TABLE #{table} DISABLE TRIGGER USER")
  end

  defp enable_recovery_triggers do
    for table <- Enum.reverse(recovery_tables()),
        do: Repo.query!("ALTER TABLE #{table} ENABLE TRIGGER USER")
  end

  defp recovery_tables,
    do: [
      "discord_identity_binding_history",
      "discord_identity_recovery_approvals",
      "discord_identity_recovery_proofs",
      "discord_identity_recovery_audit_events",
      "discord_identity_recovery_cases"
    ]

  defp fingerprint(subject), do: SubjectFingerprint.generate(subject, @fingerprint_key)
  defp manifest_key(actor_id), do: @manifest_key <> ":" <> actor_id
  defp operator_proof_key(actor_id), do: @operator_proof_key <> ":" <> actor_id
  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
