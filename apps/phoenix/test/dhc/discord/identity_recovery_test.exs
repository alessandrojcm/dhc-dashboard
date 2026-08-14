defmodule Dhc.Discord.IdentityRecoveryTest do
  use Dhc.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import Dhc.AuthFixtures

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityBindingHistory,
    IdentityRecovery,
    IdentityRecoveryApproval,
    IdentityRecoveryAuditEvent,
    IdentityRecoveryCase,
    IdentityRecoveryOperatorProofUse,
    IdentityRecoveryProof,
    SignedManifest,
    StagedAssignmentAuditEvent,
    SubjectFingerprint
  }

  alias Dhc.Repo

  @manifest_key "ale-220-manifest-key"
  @operator_proof_key "ale-220-operator-proof-key"
  @fingerprint_key "ale-220-fingerprint-key"

  setup do
    target = Dhc.MemberFixtures.member_fixture()
    operator = Dhc.MemberFixtures.member_fixture()
    subject = "discord-subject-#{System.unique_integer([:positive])}"

    identity = identity_fixture(target.principal_id, "discord", subject)
    Repo.insert!(%UserRole{principal_id: operator.principal_id, role: "admin"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      identity: identity,
      operator: operator,
      subject: subject,
      target: target,
      now: now,
      options: %{
        manifest_keys: %{operator.principal_id => manifest_key(operator.principal_id)},
        operator_proof_keys: %{
          operator.principal_id => operator_proof_key(operator.principal_id)
        },
        fingerprint_key: @fingerprint_key,
        now: now
      }
    }
  end

  test "opens one support-safe case, consumes fresh operator proof, and completely contains authentication",
       context do
    principal = Auth.get_principal!(context.target.principal_id)
    first_session = session_token(principal)
    second_session = session_token(principal)
    {:ok, socket_token} = Auth.create_socket_token(principal)
    {magic_link, _} = magic_link_token(principal)
    socket_id = DhcWeb.UserSocket.socket_id(principal.id)
    :ok = DhcWeb.Endpoint.subscribe(socket_id)

    assert {:ok, receipt} = open(context)
    assert receipt.state == "open"
    assert receipt.reason_code == "promoted_binding"
    assert receipt.reporter_reference == "support-case:123"
    assert receipt.binding_fingerprint == fingerprint(context.subject)
    assert receipt.evidence_references == ["evidence:123"]
    assert String.starts_with?(receipt.case_reference, "DIR-")
    refute inspect(receipt) =~ context.subject
    refute inspect(receipt) =~ "discord@example.test"
    refute inspect(receipt) =~ "mutable-name"

    identity = Repo.get!(ExternalIdentity, context.identity.id)
    assert identity.principal_id == context.target.principal_id
    assert identity.provider_subject == context.subject
    assert identity.sign_in_disabled_at
    assert {:error, :invalid} = Auth.get_principal_by_session_token(first_session)
    assert {:error, :invalid} = Auth.get_principal_by_session_token(second_session)
    assert {:error, :invalid} = Auth.get_principal_by_socket_token(socket_token)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^socket_id,
      event: "disconnect",
      payload: %{}
    }

    assert Repo.aggregate(IdentityRecoveryOperatorProofUse, :count) == 1
    assert {:ok, %{session_token: _}} = Auth.consume_magic_link(magic_link)
    assert {:error, :invalid} = Auth.sign_in_with_discord(%{"sub" => context.subject})

    [recovery_case] = Repo.all(IdentityRecoveryCase)
    assert recovery_case.actor_principal_id == context.operator.principal_id
    [audit] = Repo.all(IdentityRecoveryAuditEvent)
    assert audit.recovery_case_id == recovery_case.id
    assert audit.action == "opened_and_contained"
    assert audit.actor_principal_id == context.operator.principal_id
  end

  test "replay returns the active case without duplicate containment, proof use, or audit",
       context do
    session = session_token(Auth.get_principal!(context.target.principal_id))
    {manifest, proof} = signed_request(context)

    assert {:ok, first} = IdentityRecovery.open_signed(manifest, proof, context.options)
    assert {:ok, replay} = IdentityRecovery.open_signed(manifest, proof, context.options)
    assert replay == first
    assert Repo.aggregate(IdentityRecoveryCase, :count) == 1
    assert Repo.aggregate(IdentityRecoveryAuditEvent, :count) == 1
    assert Repo.aggregate(IdentityRecoveryOperatorProofUse, :count) == 1
    assert {:error, :invalid} = Auth.get_principal_by_session_token(session)
  end

  test "requires command and actor proof signatures, exact binding, matching actor, and freshness",
       context do
    {manifest, proof} = signed_request(context)

    invalid_manifest = %{manifest | "signature" => Base.url_encode64("bad", padding: false)}

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.open_signed(invalid_manifest, proof, context.options)

    invalid_proof = %{proof | "signature" => Base.url_encode64("bad", padding: false)}

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.open_signed(manifest, invalid_proof, context.options)

    other_operator = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: other_operator.principal_id, role: "admin"})

    mismatched_actor_proof =
      signed_proof(context, manifest, actor_principal_id: other_operator.principal_id)

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.open_signed(manifest, mismatched_actor_proof, context.options)

    mismatched_digest_proof =
      signed_proof(context, manifest, manifest_digest: String.duplicate("0", 64))

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.open_signed(manifest, mismatched_digest_proof, context.options)

    boundary_options = %{context.options | now: DateTime.add(context.now, 300, :second)}
    assert {:ok, _receipt} = IdentityRecovery.open_signed(manifest, proof, boundary_options)

    stale_options = %{context.options | now: DateTime.add(context.now, 301, :second)}

    assert {:error, :stale_operator_authentication} =
             IdentityRecovery.open_signed(manifest, proof, stale_options)
  end

  test "authorization is live and a contained, unknown, non-Discord, or mismatched binding fails neutrally",
       context do
    Repo.delete_all(
      from(role in UserRole, where: role.principal_id == ^context.operator.principal_id)
    )

    assert {:error, :unauthorized_operator} = open(context)

    Repo.insert!(%UserRole{principal_id: context.operator.principal_id, role: "admin"})

    unknown = put_in(command(context), ["binding_id"], Ecto.UUID.generate())
    assert {:error, :invalid_recovery_command} = open(context, unknown)

    other = Dhc.MemberFixtures.member_fixture()
    non_discord = identity_fixture(other.principal_id, "github", "provider-subject")

    non_discord_command =
      context
      |> command()
      |> Map.put("binding_id", non_discord.id)
      |> Map.put("binding_fingerprint", fingerprint("provider-subject"))

    assert {:error, :invalid_recovery_command} = open(context, non_discord_command)

    wrong_fingerprint =
      put_in(command(context), ["binding_fingerprint"], fingerprint("not-the-subject"))

    assert {:error, :invalid_recovery_command} = open(context, wrong_fingerprint)

    Repo.update_all(
      from(identity in ExternalIdentity, where: identity.id == ^context.identity.id),
      set: [sign_in_disabled_at: DateTime.utc_now()]
    )

    assert {:error, :invalid_recovery_command} = open(context)
    assert Repo.aggregate(IdentityRecoveryCase, :count) == 0
  end

  test "rejects malformed or privacy-unsafe operator fields without raising or persisting",
       context do
    malformed_values = [
      {"binding_fingerprint", "short"},
      {"binding_fingerprint", String.duplicate("A", 64)},
      {"reporter_reference", ""},
      {"reporter_reference", "person@example.test"},
      {"reporter_reference", "support-case:" <> String.duplicate("x", 97)},
      {"evidence_references", []},
      {"evidence_references", List.duplicate("evidence:x", 11)},
      {"evidence_references", ["123456789"]},
      {"evidence_references", ["evidence:" <> String.duplicate("x", 97)]}
    ]

    Enum.each(malformed_values, fn {field, value} ->
      malformed = Map.put(command(context), field, value)
      assert {:error, :invalid_recovery_command} = open(context, malformed)
    end)

    assert Repo.aggregate(IdentityRecoveryCase, :count) == 0
    assert Repo.aggregate(IdentityRecoveryAuditEvent, :count) == 0
    assert is_nil(Repo.get!(ExternalIdentity, context.identity.id).sign_in_disabled_at)
  end

  test "case creation appends exactly one database-managed immutable audit event", context do
    assert {:ok, _receipt} = open(context)
    recovery_case = Repo.one!(IdentityRecoveryCase)
    audit = Repo.one!(IdentityRecoveryAuditEvent)

    case_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn ->
            recovery_case
            |> Ecto.Changeset.change(reporter_reference: "support-case:changed")
            |> Repo.update!()
          end,
          mode: :savepoint
        )
      end

    assert case_error.constraint == "discord_identity_recovery_cases_immutable"

    case_delete_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> Repo.delete!(recovery_case) end, mode: :savepoint)
      end

    assert case_delete_error.constraint == "discord_identity_recovery_cases_immutable"

    audit_update_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn -> audit |> Ecto.Changeset.change(action: "changed") |> Repo.update!() end,
          mode: :savepoint
        )
      end

    assert audit_update_error.constraint == "discord_identity_recovery_audit_events_immutable"

    audit_delete_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> Repo.delete!(audit) end, mode: :savepoint)
      end

    assert audit_delete_error.constraint == "discord_identity_recovery_audit_events_immutable"

    duplicate_error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(
          fn ->
            Repo.insert!(%IdentityRecoveryAuditEvent{
              recovery_case_id: recovery_case.id,
              action: "opened_and_contained",
              actor_principal_id: context.operator.principal_id
            })
          end,
          mode: :savepoint
        )
      end

    assert duplicate_error.constraint == "discord_identity_recovery_audit_events_immutable"
    assert Repo.aggregate(IdentityRecoveryAuditEvent, :count) == 1
  end

  test "a proof-consumption conflict rolls back case, containment, token revocation, and audit",
       context do
    session = session_token(Auth.get_principal!(context.target.principal_id))
    {manifest, proof} = signed_request(context)

    {:ok, _proof_command, proof_digest, _signer} =
      SignedManifest.verify(proof, context.options.operator_proof_keys)

    {:ok, _command, manifest_digest, _signer} =
      SignedManifest.verify(manifest, context.options.manifest_keys)

    other = Dhc.MemberFixtures.member_fixture()
    other_identity = identity_fixture(other.principal_id, "discord", "other-recovery-subject")
    now = DateTime.utc_now()

    other_case =
      %IdentityRecoveryCase{
        external_identity_id: other_identity.id,
        case_reference: "DIR-#{String.upcase(Ecto.UUID.generate())}",
        state: "open",
        binding_fingerprint: fingerprint("other-recovery-subject"),
        actor_principal_id: context.operator.principal_id,
        opened_at: now
      }
      |> IdentityRecoveryCase.open_changeset(%{
        reason_code: "replacement_request",
        reporter_reference: "support-case:other",
        evidence_references: ["evidence:other"]
      })
      |> Repo.insert!()

    Repo.insert!(%IdentityRecoveryOperatorProofUse{
      proof_digest: proof_digest,
      manifest_digest: manifest_digest,
      actor_principal_id: context.operator.principal_id,
      recovery_case_id: other_case.id,
      consumed_at: now
    })

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.open_signed(manifest, proof, context.options)

    refute Repo.exists?(
             from(recovery_case in IdentityRecoveryCase,
               where: recovery_case.external_identity_id == ^context.identity.id
             )
           )

    assert is_nil(Repo.get!(ExternalIdentity, context.identity.id).sign_in_disabled_at)
    assert {:ok, _principal} = Auth.get_principal_by_session_token(session)
    assert Repo.aggregate(IdentityRecoveryAuditEvent, :count) == 1
  end

  test "a promoted assignment's recorded fingerprint opens recovery without translation",
       context do
    target = Dhc.MemberFixtures.member_fixture(email: "recovery-promoted@example.test")
    target_principal = Auth.get_principal!(target.principal_id)
    subject = "recovery-promoted-subject"

    assignment =
      Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(target_principal.id, subject)

    assert {:ok, _session} = Auth.sign_in_with_discord(%{"sub" => subject})
    identity = Repo.get_by!(ExternalIdentity, provider: "discord", provider_subject: subject)

    promoted_audit =
      Repo.get_by!(StagedAssignmentAuditEvent,
        assignment_id: assignment.id,
        action: "promoted"
      )

    fingerprint_key = Dhc.DiscordAssignmentFixtures.fingerprint_key()

    promoted_context = %{
      context
      | identity: identity,
        subject: subject,
        target: %{principal_id: target_principal.id},
        options: %{context.options | fingerprint_key: fingerprint_key}
    }

    assert promoted_audit.subject_fingerprint ==
             SubjectFingerprint.generate(subject, fingerprint_key)

    assert {:ok, receipt} = open(promoted_context)
    assert receipt.binding_fingerprint == promoted_audit.subject_fingerprint
  end

  test "replacement requires both fresh proofs and two exact independent approvals", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    receipt = open_case!(context)
    incoming_subject = "replacement-subject-#{System.unique_integer([:positive])}"

    assert {:ok, ^receipt} =
             IdentityRecovery.record_discord_oauth_proof(
               receipt.case_reference,
               %{
                 "sub" => incoming_subject,
                 "email" => "metadata-only@example.test",
                 "username" => "not-authority"
               },
               @fingerprint_key
             )

    refute Repo.exists?(
             from(i in ExternalIdentity, where: i.provider_subject == ^incoming_subject)
           )

    assert Repo.aggregate(
             from(token in PrincipalToken, where: token.context == "session"),
             :count
           ) == 0

    destination_principal = Auth.get_principal!(destination.principal_id)
    {magic_link, _row} = recovery_magic_link_token(destination_principal, receipt)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(receipt.case_reference, magic_link)

    assert {:error, :invalid} = Auth.get_principal_by_session_token(magic_link)
    source_session = session_token(Auth.get_principal!(context.target.principal_id))
    destination_session = session_token(destination_principal)
    {_source_login, _} = magic_link_token(Auth.get_principal!(context.target.principal_id))
    {_destination_login, _} = magic_link_token(destination_principal)

    {:ok, source_socket} =
      Auth.create_socket_token(Auth.get_principal!(context.target.principal_id))

    {:ok, destination_socket} = Auth.create_socket_token(destination_principal)
    source_socket_id = DhcWeb.UserSocket.socket_id(context.target.principal_id)
    destination_socket_id = DhcWeb.UserSocket.socket_id(destination.principal_id)
    :ok = DhcWeb.Endpoint.subscribe(source_socket_id)
    :ok = DhcWeb.Endpoint.subscribe(destination_socket_id)

    approve!(context.operator.principal_id, receipt, destination.principal_id, incoming_subject)
    approve!(second_approver.principal_id, receipt, destination.principal_id, incoming_subject)

    assert {:ok, result} = IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)
    assert result.state == "completed"
    assert result.operation == "replacement"
    assert result.incoming_subject_fingerprint == fingerprint(incoming_subject)
    refute inspect(result) =~ incoming_subject
    refute inspect(result) =~ "metadata-only@example.test"
    refute inspect(result) =~ "not-authority"

    old_identity = Repo.get!(ExternalIdentity, context.identity.id)
    assert old_identity.retired_at
    assert old_identity.principal_id == context.target.principal_id

    new_identity =
      Repo.one!(
        from(i in ExternalIdentity,
          where: i.provider_subject == ^incoming_subject and is_nil(i.retired_at)
        )
      )

    assert new_identity.principal_id == destination.principal_id
    assert new_identity.metadata == %{}
    assert {:error, :invalid} = Auth.get_principal_by_session_token(source_session)
    assert {:error, :invalid} = Auth.get_principal_by_session_token(destination_session)
    assert {:error, :invalid} = Auth.get_principal_by_socket_token(source_socket)
    assert {:error, :invalid} = Auth.get_principal_by_socket_token(destination_socket)

    refute Repo.exists?(
             from(t in PrincipalToken,
               where:
                 t.principal_id in ^[context.target.principal_id, destination.principal_id] and
                   (t.context in ["session", "socket", "login"] or
                      like(t.context, "identity_recovery:%"))
             )
           )

    assert_receive %Phoenix.Socket.Broadcast{topic: ^source_socket_id, event: "disconnect"}
    assert_receive %Phoenix.Socket.Broadcast{topic: ^destination_socket_id, event: "disconnect"}

    [history] = Repo.all(IdentityBindingHistory)
    assert history.old_external_identity_id == old_identity.id
    assert history.new_external_identity_id == new_identity.id
    assert history.operation == "replacement"
    assert Repo.aggregate(IdentityRecoveryProof, :count) == 2
    assert Repo.aggregate(IdentityRecoveryApproval, :count) == 2

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    assert {:ok, %{principal: signed_in, session_token: _}} =
             Auth.sign_in_with_discord(%{"sub" => incoming_subject})

    assert signed_in.id == destination.principal_id
    assert_raise Postgrex.Error, fn -> Repo.delete!(history) end
  end

  test "transfer preserves the retired binding and moves the same proved subject", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    receipt = open_case!(context)

    prove_case!(receipt, destination.principal_id, context.subject)
    approve!(context.operator.principal_id, receipt, destination.principal_id, context.subject)
    approve!(second_approver.principal_id, receipt, destination.principal_id, context.subject)

    assert {:ok, %{operation: "transfer"}} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    identities =
      Repo.all(
        from(i in ExternalIdentity,
          where: i.provider == "discord" and i.provider_subject == ^context.subject,
          order_by: i.created_at
        )
      )

    assert [retired, active] = identities
    assert retired.id == context.identity.id
    assert retired.retired_at
    assert active.principal_id == destination.principal_id
    assert is_nil(active.retired_at)
  end

  test "one-sided, duplicate, stale, and changed approvals fail closed", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    receipt = open_case!(context)
    incoming_subject = "approval-subject-#{System.unique_integer([:positive])}"
    prove_case!(receipt, destination.principal_id, incoming_subject)

    first_approval =
      approval_command(
        context.operator.principal_id,
        receipt,
        destination.principal_id,
        incoming_subject
      )

    {:ok, first_approval_issued_at, 0} = DateTime.from_iso8601(first_approval["issued_at"])

    assert {:ok, ^receipt} =
             approve_command(
               context.operator.principal_id,
               first_approval,
               first_approval_issued_at
             )

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    assert {:ok, ^receipt} =
             approve_command(
               context.operator.principal_id,
               first_approval,
               first_approval_issued_at
             )

    assert Repo.aggregate(IdentityRecoveryApproval, :count) == 1

    changed =
      approval_command(
        second_approver.principal_id,
        receipt,
        destination.principal_id,
        incoming_subject,
        context.now
      )
      |> Map.put("evidence_references", ["support-said-so"])

    assert {:error, :invalid_recovery_command} =
             approve_command(second_approver.principal_id, changed, context.now)

    stale_now = DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -301, :second)

    stale_command =
      approval_command(
        second_approver.principal_id,
        receipt,
        destination.principal_id,
        incoming_subject,
        stale_now
      )

    assert {:ok, _} =
             approve_command(second_approver.principal_id, stale_command, stale_now)

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    source = Repo.get!(ExternalIdentity, context.identity.id)
    assert is_nil(source.retired_at)
    assert source.sign_in_disabled_at
    assert Repo.aggregate(IdentityBindingHistory, :count) == 0
  end

  test "approval identity is derived from distinct Ed25519 credentials", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    receipt = open_case!(context)
    incoming_subject = "credential-subject-#{System.unique_integer([:positive])}"
    prove_case!(receipt, destination.principal_id, incoming_subject)

    command =
      approval_command(
        context.operator.principal_id,
        receipt,
        destination.principal_id,
        incoming_subject
      )

    {:ok, issued_at, 0} = DateTime.from_iso8601(command["issued_at"])
    {first_public, first_private} = :crypto.generate_key(:eddsa, :ed25519)
    {second_public, _second_private} = :crypto.generate_key(:eddsa, :ed25519)
    envelope = SignedManifest.sign_ed25519(command, first_private)

    refute Map.has_key?(command, "actor_principal_id")

    assert {:error, :invalid_manifest_signature} =
             IdentityRecovery.approve_signed(envelope, %{
               approver_public_keys: %{second_approver.principal_id => second_public},
               now: issued_at
             })

    assert {:ok, _} =
             IdentityRecovery.approve_signed(envelope, %{
               approver_public_keys: %{context.operator.principal_id => first_public},
               now: issued_at
             })

    assert Repo.one!(IdentityRecoveryApproval).approver_principal_id ==
             context.operator.principal_id
  end

  test "rejects a third live approval without poisoning completion", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    third_approver = authorized_operator()
    receipt = open_case!(context)
    incoming_subject = "third-approval-subject-#{System.unique_integer([:positive])}"
    prove_case!(receipt, destination.principal_id, incoming_subject)

    approve!(context.operator.principal_id, receipt, destination.principal_id, incoming_subject)
    approve!(second_approver.principal_id, receipt, destination.principal_id, incoming_subject)

    assert {:error, :invalid_recovery_command} =
             approve(
               third_approver.principal_id,
               receipt,
               destination.principal_id,
               incoming_subject
             )

    assert Repo.aggregate(IdentityRecoveryApproval, :count) == 2

    assert {:ok, %{state: "completed"}} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)
  end

  test "appends fresh proof and approval attempts after expiry", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    receipt = open_case!(context)
    incoming_subject = "refresh-subject-#{System.unique_integer([:positive])}"
    expired_now = DateTime.add(context.now, -301, :second)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_discord_oauth_proof(
               receipt.case_reference,
               %{"sub" => incoming_subject},
               @fingerprint_key,
               expired_now
             )

    assert {:ok, ^receipt} =
             IdentityRecovery.record_discord_oauth_proof(
               receipt.case_reference,
               %{"sub" => incoming_subject},
               @fingerprint_key,
               context.now
             )

    principal = Auth.get_principal!(destination.principal_id)
    {expired_token, _} = recovery_magic_link_token(principal, receipt)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(
               receipt.case_reference,
               expired_token,
               expired_now
             )

    {fresh_token, _} = recovery_magic_link_token(principal, receipt)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(
               receipt.case_reference,
               fresh_token,
               context.now
             )

    assert [1, 2] ==
             Repo.all(
               from(p in IdentityRecoveryProof,
                 where: p.kind == "discord_oauth",
                 order_by: p.attempt,
                 select: p.attempt
               )
             )

    expired_command =
      approval_command(
        context.operator.principal_id,
        receipt,
        destination.principal_id,
        incoming_subject,
        expired_now
      )

    assert {:ok, _} =
             approve_command(context.operator.principal_id, expired_command, expired_now)

    approve!(context.operator.principal_id, receipt, destination.principal_id, incoming_subject)
    approve!(second_approver.principal_id, receipt, destination.principal_id, incoming_subject)

    assert Repo.aggregate(
             from(a in IdentityRecoveryApproval,
               where: a.approver_principal_id == ^context.operator.principal_id
             ),
             :count
           ) == 2

    assert {:ok, %{state: "completed"}} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    assert Repo.aggregate(IdentityRecoveryProof, :count) == 4
    assert Repo.aggregate(IdentityRecoveryApproval, :count) == 3
  end

  test "terminalizes an unresolved case immutably and permits a fresh contained case", context do
    receipt = open_case!(context)

    close_command = %{
      "version" => 1,
      "action" => "close",
      "issued_at" => DateTime.to_iso8601(context.now),
      "case_reference" => receipt.case_reference,
      "outcome" => "expired",
      "reason_code" => "proof_window_expired",
      "actor_principal_id" => context.operator.principal_id
    }

    assert {:ok, %{state: "expired"}} =
             IdentityRecovery.close_signed(
               SignedManifest.sign(
                 close_command,
                 context.operator.principal_id,
                 manifest_key(context.operator.principal_id)
               ),
               context.options
             )

    expired = Repo.get_by!(IdentityRecoveryCase, case_reference: receipt.case_reference)
    assert expired.terminal_at
    assert expired.terminal_reason_code == "proof_window_expired"
    assert Repo.get!(ExternalIdentity, context.identity.id).sign_in_disabled_at

    assert {:ok, replacement_case} = open(context)

    refute replacement_case.case_reference == receipt.case_reference
    assert replacement_case.state == "open"
    assert Repo.aggregate(IdentityRecoveryCase, :count) == 2
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(expired) end
  end

  test "a permanent destination conflict rolls back without weakening containment", context do
    destination = Dhc.MemberFixtures.member_fixture()
    second_approver = authorized_operator()
    destination_principal = Auth.get_principal!(destination.principal_id)

    %ExternalIdentity{}
    |> ExternalIdentity.create_changeset(destination_principal, %{
      provider: "discord",
      provider_subject: "destination-existing-subject",
      metadata: %{}
    })
    |> Repo.insert!()

    receipt = open_case!(context)
    incoming_subject = "conflicted-replacement-#{System.unique_integer([:positive])}"
    prove_case!(receipt, destination.principal_id, incoming_subject)
    approve!(context.operator.principal_id, receipt, destination.principal_id, incoming_subject)
    approve!(second_approver.principal_id, receipt, destination.principal_id, incoming_subject)

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    source = Repo.get!(ExternalIdentity, context.identity.id)
    assert is_nil(source.retired_at)
    assert source.sign_in_disabled_at

    assert Repo.get_by!(IdentityRecoveryCase, case_reference: receipt.case_reference).state ==
             "open"

    assert Repo.aggregate(IdentityBindingHistory, :count) == 0
  end

  test "Mix CLI accepts both signed envelopes and emits only a support-safe receipt", context do
    {manifest, proof} = signed_request(context)
    directory = temp_directory!()
    manifest_path = Path.join(directory, "manifest.json")
    proof_path = Path.join(directory, "proof.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(proof_path, Jason.encode!(proof))
    install_cli_env(context.options)
    Mix.Task.reenable("dhc.discord.identity_recovery")

    output =
      capture_io(fn ->
        Mix.Tasks.Dhc.Discord.IdentityRecovery.run(["open", manifest_path, proof_path])
      end)

    assert output =~ "case_reference"
    assert output =~ "binding_fingerprint"
    refute output =~ context.subject
    refute output =~ "discord@example.test"
    refute output =~ "mutable-name"
  end

  test "Mix CLI fails malformed input with one neutral message", context do
    operator_email = Auth.get_principal!(context.operator.principal_id).email
    malformed = Map.put(command(context), "reporter_reference", operator_email)
    {manifest, proof} = signed_request(context, malformed)
    directory = temp_directory!()
    manifest_path = Path.join(directory, "manifest.json")
    proof_path = Path.join(directory, "proof.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(proof_path, Jason.encode!(proof))
    install_cli_env(context.options)
    Mix.Task.reenable("dhc.discord.identity_recovery")

    output =
      capture_io(fn ->
        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Dhc.Discord.IdentityRecovery.run(["open", manifest_path, proof_path])
          end

        assert error.message == "Discord identity recovery command failed safely"
      end)

    refute output =~ operator_email
    refute output =~ context.subject
  end

  defp open(context, command \\ nil) do
    {manifest, proof} = signed_request(context, command || command(context))
    IdentityRecovery.open_signed(manifest, proof, context.options)
  end

  defp signed_request(context, command \\ nil) do
    command = command || command(context)
    actor_id = context.operator.principal_id
    manifest = SignedManifest.sign(command, actor_id, manifest_key(actor_id))
    {manifest, signed_proof(context, manifest)}
  end

  defp signed_proof(context, manifest, overrides \\ []) do
    actor_id = context.operator.principal_id

    {:ok, _command, manifest_digest, ^actor_id} =
      SignedManifest.verify(manifest, context.options.manifest_keys)

    proof = %{
      "version" => 1,
      "action" => "authorize_identity_recovery",
      "issued_at" => DateTime.to_iso8601(context.now),
      "manifest_digest" => Keyword.get(overrides, :manifest_digest, manifest_digest),
      "actor_principal_id" =>
        Keyword.get(overrides, :actor_principal_id, context.operator.principal_id),
      "nonce" => Ecto.UUID.generate()
    }

    SignedManifest.sign(proof, actor_id, operator_proof_key(actor_id))
  end

  defp open_case!(context) do
    assert {:ok, receipt} = open(context)
    receipt
  end

  defp authorized_operator do
    operator = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: operator.principal_id, role: "admin"})
    operator
  end

  defp prove_case!(receipt, destination_principal_id, incoming_subject) do
    assert {:ok, ^receipt} =
             IdentityRecovery.record_discord_oauth_proof(
               receipt.case_reference,
               %{"sub" => incoming_subject},
               @fingerprint_key
             )

    {token, _row} =
      recovery_magic_link_token(Auth.get_principal!(destination_principal_id), receipt)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(receipt.case_reference, token)
  end

  defp approve!(actor_id, receipt, destination_id, incoming_subject) do
    assert {:ok, _} = approve(actor_id, receipt, destination_id, incoming_subject)
  end

  defp approve(actor_id, receipt, destination_id, incoming_subject) do
    command = approval_command(actor_id, receipt, destination_id, incoming_subject)
    {:ok, issued_at, 0} = DateTime.from_iso8601(command["issued_at"])

    approve_command(actor_id, command, issued_at)
  end

  defp approve_command(actor_id, command, now) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    IdentityRecovery.approve_signed(
      SignedManifest.sign_ed25519(command, private_key),
      %{approver_public_keys: %{actor_id => public_key}, now: now}
    )
  end

  defp approval_command(_actor_id, receipt, destination_id, incoming_subject, now \\ nil) do
    now = now || DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      "version" => 1,
      "action" => "approve",
      "issued_at" => DateTime.to_iso8601(now),
      "case_reference" => receipt.case_reference,
      "source_binding_fingerprint" => receipt.binding_fingerprint,
      "destination_principal_id" => destination_id,
      "incoming_subject_fingerprint" => fingerprint(incoming_subject),
      "evidence_references" => receipt.evidence_references,
      "operation" =>
        if(receipt.binding_fingerprint == fingerprint(incoming_subject),
          do: "transfer",
          else: "replacement"
        )
    }
  end

  defp recovery_magic_link_token(principal, receipt) do
    recovery_case = Repo.get_by!(IdentityRecoveryCase, case_reference: receipt.case_reference)
    {token, row} = PrincipalToken.build_identity_recovery_token(principal, recovery_case.id)
    Repo.insert!(row)
    {token, row}
  end

  defp command(context) do
    %{
      "version" => 1,
      "action" => "open",
      "issued_at" => DateTime.to_iso8601(context.now),
      "binding_id" => context.identity.id,
      "binding_fingerprint" =>
        SubjectFingerprint.generate(context.subject, context.options.fingerprint_key),
      "reporter_reference" => "support-case:123",
      "reason_code" => "promoted_binding",
      "evidence_references" => ["evidence:123"],
      "actor_principal_id" => context.operator.principal_id
    }
  end

  defp fingerprint(subject), do: SubjectFingerprint.generate(subject, @fingerprint_key)

  defp identity_fixture(principal_id, provider, subject) do
    principal = Auth.get_principal!(principal_id)

    %ExternalIdentity{}
    |> ExternalIdentity.create_changeset(principal, %{
      provider: provider,
      provider_subject: subject,
      metadata: %{"email" => "discord@example.test", "username" => "mutable-name"}
    })
    |> Repo.insert!()
  end

  defp temp_directory! do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ale-220-cli-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    directory
  end

  defp install_cli_env(options) do
    env = %{
      "DISCORD_IDENTITY_RECOVERY_MANIFEST_KEYS" => Jason.encode!(options.manifest_keys),
      "DISCORD_IDENTITY_RECOVERY_OPERATOR_PROOF_KEYS" =>
        Jason.encode!(options.operator_proof_keys),
      "DISCORD_SUBJECT_FINGERPRINT_KEY" => options.fingerprint_key
    }

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  defp manifest_key(actor_id), do: @manifest_key <> ":" <> actor_id
  defp operator_proof_key(actor_id), do: @operator_proof_key <> ":" <> actor_id
end
