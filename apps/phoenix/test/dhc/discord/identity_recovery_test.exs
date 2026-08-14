defmodule Dhc.Discord.IdentityRecoveryTest do
  use Dhc.DataCase, async: false

  import Ecto.Query
  import Dhc.AuthFixtures

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityRecovery,
    IdentityRecoveryAuditEvent,
    IdentityRecoveryCase,
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

  defp envelope(context), do: command(context) |> SignedManifest.sign(@manifest_key)

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
