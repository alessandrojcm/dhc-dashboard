defmodule Dhc.Discord.IdentityRecoveryTest do
  use Dhc.DataCase, async: false

  import Ecto.Query
  import Dhc.AuthFixtures

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityBindingHistory,
    IdentityRecovery,
    IdentityRecoveryApproval,
    IdentityRecoveryAuditEvent,
    IdentityRecoveryCase,
    IdentityRecoveryProof,
    SignedManifest
  }

  alias Dhc.Repo

  @manifest_key "ale-220-manifest-key"
  @fingerprint_key "ale-220-fingerprint-key"

  setup do
    target = Dhc.MemberFixtures.member_fixture()
    operator = Dhc.MemberFixtures.member_fixture()
    subject = "discord-subject-#{System.unique_integer([:positive])}"

    identity =
      %ExternalIdentity{}
      |> ExternalIdentity.create_changeset(Auth.get_principal!(target.principal_id), %{
        provider: "discord",
        provider_subject: subject,
        metadata: %{"email" => "discord@example.test", "username" => "mutable-name"}
      })
      |> Repo.insert!()

    Repo.insert!(%UserRole{principal_id: operator.principal_id, role: "admin"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      identity: identity,
      operator: operator,
      subject: subject,
      target: target,
      now: now,
      options: %{manifest_key: @manifest_key, fingerprint_key: @fingerprint_key, now: now}
    }
  end

  test "opens one support-safe case, contains sign-in, revokes sessions, and preserves ownership",
       context do
    first_session = session_token(Auth.get_principal!(context.target.principal_id))
    second_session = session_token(Auth.get_principal!(context.target.principal_id))
    {magic_link, _} = magic_link_token(Auth.get_principal!(context.target.principal_id))

    assert {:ok, receipt} = IdentityRecovery.open_signed(envelope(context), context.options)
    assert receipt.state == "open"
    assert receipt.reason_code == "promoted_binding"
    assert receipt.reporter_reference == "support-case-123"
    assert receipt.binding_fingerprint == fingerprint(context.subject)
    assert receipt.evidence_references == ["evidence-123"]
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

    assert Repo.aggregate(
             from(token in PrincipalToken, where: token.context == "session"),
             :count
           ) == 0

    assert {:ok, %{session_token: _}} = Auth.consume_magic_link(magic_link)
    assert {:error, :invalid} = Auth.sign_in_with_discord(%{"sub" => context.subject})

    [recovery_case] = Repo.all(IdentityRecoveryCase)
    assert recovery_case.external_identity_id == context.identity.id
    assert recovery_case.actor_principal_id == context.operator.principal_id
    assert recovery_case.binding_fingerprint == fingerprint(context.subject)
    assert recovery_case.evidence_references == ["evidence-123"]

    [audit] = Repo.all(IdentityRecoveryAuditEvent)
    assert audit.recovery_case_id == recovery_case.id
    assert audit.action == "opened_and_contained"
    assert audit.actor_principal_id == context.operator.principal_id
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(audit) end
  end

  test "replay returns the active case without duplicate containment or audit", context do
    session = session_token(Auth.get_principal!(context.target.principal_id))
    envelope = envelope(context)

    assert {:ok, first} = IdentityRecovery.open_signed(envelope, context.options)
    assert {:ok, replay} = IdentityRecovery.open_signed(envelope, context.options)
    assert replay == first
    assert Repo.aggregate(IdentityRecoveryCase, :count) == 1
    assert Repo.aggregate(IdentityRecoveryAuditEvent, :count) == 1
    assert {:error, :invalid} = Auth.get_principal_by_session_token(session)
  end

  test "requires a fresh signed command, an authorized operator, and a matching fingerprint",
       context do
    stale = %{
      context
      | options: %{context.options | now: DateTime.add(context.now, 301, :second)}
    }

    assert {:error, :stale_operator_authentication} =
             IdentityRecovery.open_signed(envelope(context), stale.options)

    unauthorized = Dhc.MemberFixtures.member_fixture()
    unauthorized_command = command(%{context | operator: unauthorized})

    assert {:error, :unauthorized_operator} =
             IdentityRecovery.open_signed(
               SignedManifest.sign(unauthorized_command, @manifest_key),
               context.options
             )

    wrong_fingerprint =
      put_in(command(context), ["binding_fingerprint"], fingerprint("not-the-subject"))

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.open_signed(
               SignedManifest.sign(wrong_fingerprint, @manifest_key),
               context.options
             )

    assert Repo.aggregate(IdentityRecoveryCase, :count) == 0
    assert is_nil(Repo.get!(ExternalIdentity, context.identity.id).sign_in_disabled_at)
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
    {magic_link, _row} = magic_link_token(destination_principal)

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(receipt.case_reference, magic_link)

    assert {:error, :invalid} = Auth.get_principal_by_session_token(magic_link)
    source_session = session_token(Auth.get_principal!(context.target.principal_id))
    destination_session = session_token(destination_principal)

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
    assert Repo.aggregate(from(t in PrincipalToken, where: t.context == "session"), :count) == 0

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

    approve!(context.operator.principal_id, receipt, destination.principal_id, incoming_subject)

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    assert {:error, :invalid_recovery_operation} =
             approve(
               context.operator.principal_id,
               receipt,
               destination.principal_id,
               incoming_subject
             )

    changed =
      approval_command(
        second_approver.principal_id,
        receipt,
        destination.principal_id,
        incoming_subject
      )
      |> Map.put("evidence_references", ["support-said-so"])

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.approve_signed(
               SignedManifest.sign(changed, @manifest_key),
               context.options
             )

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
             IdentityRecovery.approve_signed(
               SignedManifest.sign(stale_command, @manifest_key),
               %{context.options | now: stale_now}
             )

    assert {:error, :invalid_recovery_command} =
             IdentityRecovery.complete(receipt.case_reference, @fingerprint_key)

    source = Repo.get!(ExternalIdentity, context.identity.id)
    assert is_nil(source.retired_at)
    assert source.sign_in_disabled_at
    assert Repo.aggregate(IdentityBindingHistory, :count) == 0
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

  defp envelope(context), do: command(context) |> SignedManifest.sign(@manifest_key)

  defp open_case!(context) do
    assert {:ok, receipt} = IdentityRecovery.open_signed(envelope(context), context.options)
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

    {token, _row} = magic_link_token(Auth.get_principal!(destination_principal_id))

    assert {:ok, ^receipt} =
             IdentityRecovery.record_magic_link_proof(receipt.case_reference, token)
  end

  defp approve!(actor_id, receipt, destination_id, incoming_subject) do
    assert {:ok, _} = approve(actor_id, receipt, destination_id, incoming_subject)
  end

  defp approve(actor_id, receipt, destination_id, incoming_subject) do
    command = approval_command(actor_id, receipt, destination_id, incoming_subject)
    {:ok, issued_at, 0} = DateTime.from_iso8601(command["issued_at"])

    IdentityRecovery.approve_signed(
      SignedManifest.sign(command, @manifest_key),
      %{manifest_key: @manifest_key, now: issued_at}
    )
  end

  defp approval_command(actor_id, receipt, destination_id, incoming_subject, now \\ nil) do
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
        ),
      "actor_principal_id" => actor_id
    }
  end

  defp command(context) do
    %{
      "version" => 1,
      "action" => "open",
      "issued_at" => DateTime.to_iso8601(context.now),
      "binding_id" => context.identity.id,
      "binding_fingerprint" => fingerprint(context.subject),
      "reporter_reference" => "support-case-123",
      "reason_code" => "promoted_binding",
      "evidence_references" => ["evidence-123"],
      "actor_principal_id" => context.operator.principal_id
    }
  end

  defp fingerprint(subject),
    do: :crypto.mac(:hmac, :sha256, @fingerprint_key, subject) |> Base.encode16(case: :lower)
end
