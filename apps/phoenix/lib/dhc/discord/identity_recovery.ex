defmodule Dhc.Discord.IdentityRecovery do
  @moduledoc """
  Runs the dual-controlled Discord identity recovery workflow.

  A signed, short-lived operator manifest opens and contains a case without
  exposing the Discord subject. Case-bound OAuth and destination magic-link
  proofs establish the requested operation without creating an identity or
  Session. Two distinct authorized operators must then sign the exact operation
  before one transaction retires the source binding, creates the destination
  binding, writes immutable history, and revokes every affected Session.
  """

  import Ecto.Query

  alias Dhc.Auth.{DiscordSubjectLock, ExternalIdentity, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityBindingHistory,
    IdentityRecoveryApproval,
    IdentityRecoveryAuditEvent,
    IdentityRecoveryCase,
    IdentityRecoveryProof,
    SignedManifest,
    StagedAssignment
  }

  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo

  @operator_roles ~w(admin president)
  @reason_codes ~w(promoted_binding replacement_request)
  @freshness_seconds 300

  def active_case?(case_reference) when is_binary(case_reference) do
    Repo.exists?(
      from(recovery_case in IdentityRecoveryCase,
        where: recovery_case.case_reference == ^case_reference and recovery_case.state == "open"
      )
    )
  end

  def active_case?(_), do: false

  @doc "Records a callback-verified OAuth subject as a short-lived recovery proof. It never links an identity or mints a Session."
  def record_discord_oauth_proof(case_reference, %{"sub" => subject}, fingerprint_key)
      when is_binary(case_reference) and is_binary(subject) and subject != "" and
             is_binary(fingerprint_key) do
    record_proof(
      case_reference,
      "discord_oauth",
      %{subject: subject, subject_fingerprint: fingerprint(subject, fingerprint_key)},
      proof_digest(subject, fingerprint_key)
    )
  end

  def record_discord_oauth_proof(_, _, _), do: {:error, :invalid_recovery_proof}

  @doc "Consumes a normal magic-link credential as recovery proof only; it deliberately does not establish a Session."
  def record_magic_link_proof(case_reference, token)
      when is_binary(case_reference) and is_binary(token) do
    with {:ok, query} <- PrincipalToken.verify_magic_link_token_query(token) do
      Repo.transaction(fn ->
        case Repo.one(query |> lock("FOR UPDATE")) do
          {principal, token_row} ->
            Repo.delete!(token_row)

            record_proof_locked(
              case_reference,
              "destination_magic_link",
              %{principal_id: principal.id},
              token |> PrincipalToken.hash_token() |> Base.encode16(case: :lower)
            )

          nil ->
            Repo.rollback(:invalid_recovery_proof)
        end
      end)
      |> transaction_result()
    else
      _ -> {:error, :invalid_recovery_proof}
    end
  end

  def record_magic_link_proof(_, _), do: {:error, :invalid_recovery_proof}

  @doc "Accepts an independently signed administrator approval of the exact proof-bound operation."
  def approve_signed(envelope, options) when is_map(options) do
    with {:ok, command, digest} <- SignedManifest.verify(envelope, options.manifest_key),
         :ok <- exact_approval_command(command),
         :ok <- fresh_command?(command["issued_at"], Map.get(options, :now, DateTime.utc_now())),
         :ok <- authorize_operator(command["actor_principal_id"]) do
      approve(command, digest, Map.get(options, :now, DateTime.utc_now()))
    end
  end

  def approve_signed(_, _), do: {:error, :invalid_recovery_command}

  def complete(case_reference, fingerprint_key)
      when is_binary(case_reference) and is_binary(fingerprint_key) do
    Repo.transaction(fn -> complete_locked(case_reference, fingerprint_key) end)
    |> transaction_result()
  rescue
    Postgrex.Error -> {:error, :invalid_recovery_operation}
    Ecto.ConstraintError -> {:error, :invalid_recovery_operation}
  end

  def complete(_, _), do: {:error, :invalid_recovery_operation}

  def open_signed(envelope, options) when is_map(options) do
    with {:ok, command, _digest} <- SignedManifest.verify(envelope, options.manifest_key),
         :ok <- exact_open_command(command),
         :ok <- fresh_command?(command["issued_at"], Map.get(options, :now, DateTime.utc_now())),
         :ok <- authorize_operator(command["actor_principal_id"]) do
      open(command, options.fingerprint_key)
    end
  end

  def open_signed(_, _), do: {:error, :invalid_recovery_command}

  defp open(command, fingerprint_key) when is_binary(fingerprint_key) and fingerprint_key != "" do
    Repo.transaction(fn ->
      identity =
        Repo.one(
          from(identity in ExternalIdentity,
            where:
              identity.id == ^command["binding_id"] and identity.provider == "discord" and
                is_nil(identity.retired_at),
            lock: "FOR UPDATE"
          )
        )

      case identity do
        nil -> Repo.rollback(:invalid_recovery_command)
        identity -> open_locked(identity, command, fingerprint_key)
      end
    end)
    |> transaction_result()
  end

  defp open(_, _), do: {:error, :invalid_recovery_command}

  defp open_locked(identity, command, fingerprint_key) do
    expected_fingerprint = fingerprint(identity.provider_subject, fingerprint_key)

    if not Plug.Crypto.secure_compare(command["binding_fingerprint"], expected_fingerprint) do
      Repo.rollback(:invalid_recovery_command)
    end

    existing_case =
      Repo.one(
        from(recovery_case in IdentityRecoveryCase,
          where:
            recovery_case.external_identity_id == ^identity.id and recovery_case.state == "open",
          lock: "FOR UPDATE"
        )
      )

    if existing_case do
      receipt(existing_case)
    else
      if not is_nil(identity.sign_in_disabled_at), do: Repo.rollback(:invalid_recovery_command)

      now = DateTime.utc_now()

      recovery_case =
        %IdentityRecoveryCase{}
        |> IdentityRecoveryCase.open_changeset(%{
          external_identity_id: identity.id,
          case_reference: case_reference(),
          state: "open",
          reason_code: command["reason_code"],
          reporter_reference: command["reporter_reference"],
          binding_fingerprint: expected_fingerprint,
          evidence_references: command["evidence_references"],
          actor_principal_id: command["actor_principal_id"],
          opened_at: now
        })
        |> Repo.insert!()

      {1, _} =
        Repo.update_all(
          from(external_identity in ExternalIdentity,
            where: external_identity.id == ^identity.id
          ),
          set: [sign_in_disabled_at: now]
        )

      Repo.delete_all(
        from(token in Dhc.Auth.PrincipalToken,
          where: token.principal_id == ^identity.principal_id and token.context == "session"
        )
      )

      %IdentityRecoveryAuditEvent{}
      |> IdentityRecoveryAuditEvent.open_changeset(%{
        recovery_case_id: recovery_case.id,
        action: "opened_and_contained",
        actor_principal_id: command["actor_principal_id"]
      })
      |> Repo.insert!()

      receipt(recovery_case)
    end
  end

  defp receipt(recovery_case) do
    %{
      case_reference: recovery_case.case_reference,
      state: recovery_case.state,
      reason_code: recovery_case.reason_code,
      reporter_reference: recovery_case.reporter_reference,
      binding_fingerprint: recovery_case.binding_fingerprint,
      evidence_references: recovery_case.evidence_references
    }
  end

  defp record_proof(case_reference, kind, attrs, digest) do
    Repo.transaction(fn -> record_proof_locked(case_reference, kind, attrs, digest) end)
    |> transaction_result()
  end

  defp record_proof_locked(case_reference, kind, attrs, digest) do
    recovery_case =
      Repo.one(
        from(c in IdentityRecoveryCase,
          where: c.case_reference == ^case_reference,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(recovery_case) or recovery_case.state != "open",
      do: Repo.rollback(:invalid_recovery_proof)

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @freshness_seconds, :second)

    existing =
      Repo.one(
        from(p in IdentityRecoveryProof,
          where: p.recovery_case_id == ^recovery_case.id and p.kind == ^kind,
          lock: "FOR UPDATE"
        )
      )

    proof_attrs =
      Map.merge(attrs, %{
        recovery_case_id: recovery_case.id,
        kind: kind,
        proof_digest: digest,
        expires_at: expires_at
      })

    cond do
      is_nil(existing) ->
        Repo.insert!(struct(IdentityRecoveryProof, proof_attrs))
        audit!(recovery_case.id, "#{kind}_proved", recovery_case.actor_principal_id)
        receipt(recovery_case)

      matching_proof?(existing, proof_attrs) and DateTime.after?(existing.expires_at, now) ->
        receipt(recovery_case)

      true ->
        Repo.rollback(:invalid_recovery_proof)
    end
  end

  defp approve(command, digest, now) do
    now = usec_precision(now)

    Repo.transaction(fn ->
      recovery_case =
        Repo.one(
          from(c in IdentityRecoveryCase,
            where: c.case_reference == ^command["case_reference"],
            lock: "FOR UPDATE"
          )
        )

      if is_nil(recovery_case) or recovery_case.state != "open",
        do: Repo.rollback(:invalid_recovery_operation)

      validate_approval_operation!(recovery_case, command, now)

      %IdentityRecoveryApproval{}
      |> Ecto.Changeset.change(%{
        recovery_case_id: recovery_case.id,
        approver_principal_id: command["actor_principal_id"],
        approval_digest: digest,
        source_binding_fingerprint: command["source_binding_fingerprint"],
        destination_principal_id: command["destination_principal_id"],
        incoming_subject_fingerprint: command["incoming_subject_fingerprint"],
        evidence_references: command["evidence_references"],
        operation: command["operation"],
        expires_at: DateTime.add(now, @freshness_seconds, :second)
      })
      |> Repo.insert!()

      audit!(recovery_case.id, "approved", command["actor_principal_id"])
      receipt(recovery_case)
    end)
    |> transaction_result()
  rescue
    Ecto.ConstraintError -> {:error, :invalid_recovery_operation}
  end

  defp complete_locked(case_reference, fingerprint_key) do
    recovery_case =
      Repo.one(
        from(c in IdentityRecoveryCase,
          where: c.case_reference == ^case_reference,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(recovery_case) or recovery_case.state != "open",
      do: Repo.rollback(:invalid_recovery_operation)

    source =
      Repo.one(
        from(i in ExternalIdentity,
          where:
            i.id == ^recovery_case.external_identity_id and i.provider == "discord" and
              is_nil(i.retired_at),
          lock: "FOR UPDATE"
        )
      )

    if is_nil(source), do: Repo.rollback(:invalid_recovery_operation)

    oauth = live_proof!(recovery_case.id, "discord_oauth")
    destination_proof = live_proof!(recovery_case.id, "destination_magic_link")
    destination_id = destination_proof.principal_id
    incoming_subject = oauth.subject
    incoming_fingerprint = fingerprint(incoming_subject, fingerprint_key)

    if not Plug.Crypto.secure_compare(
         fingerprint(source.provider_subject, fingerprint_key),
         recovery_case.binding_fingerprint
       ) or
         not Plug.Crypto.secure_compare(incoming_fingerprint, oauth.subject_fingerprint) do
      Repo.rollback(:invalid_recovery_operation)
    end

    lock_principals!([source.principal_id, destination_id])
    lock_subjects!([source.provider_subject, incoming_subject])

    operation =
      if source.provider_subject == incoming_subject, do: "transfer", else: "replacement"

    if operation == "transfer" and source.principal_id == destination_id,
      do: Repo.rollback(:invalid_recovery_operation)

    approvals =
      Repo.all(
        from(a in IdentityRecoveryApproval,
          where: a.recovery_case_id == ^recovery_case.id and a.expires_at > ^DateTime.utc_now(),
          lock: "FOR UPDATE"
        )
      )

    if length(approvals) != 2 or
         Enum.uniq_by(approvals, & &1.approver_principal_id) |> length() != 2 or
         Enum.any?(
           approvals,
           &(not approval_matches?(
               &1,
               recovery_case,
               destination_id,
               incoming_fingerprint,
               operation
             ))
         ) or
         Enum.any?(approvals, &(authorize_operator(&1.approver_principal_id) != :ok)),
       do: Repo.rollback(:invalid_recovery_operation)

    fail_on_conflict!(source, destination_id, incoming_subject)
    now = DateTime.utc_now()
    source |> Ecto.Changeset.change(retired_at: now, sign_in_disabled_at: now) |> Repo.update!()
    destination = Repo.get!(Dhc.Auth.Principal, destination_id)

    new_identity =
      ExternalIdentity.create_changeset(%ExternalIdentity{}, destination, %{
        provider: "discord",
        provider_subject: incoming_subject,
        metadata: %{}
      })
      |> Repo.insert!()

    Repo.insert!(%IdentityBindingHistory{
      recovery_case_id: recovery_case.id,
      old_external_identity_id: source.id,
      new_external_identity_id: new_identity.id,
      source_principal_id: source.principal_id,
      destination_principal_id: destination_id,
      operation: operation,
      incoming_subject_fingerprint: incoming_fingerprint
    })

    recovery_case
    |> Ecto.Changeset.change(
      destination_principal_id: destination_id,
      incoming_subject_fingerprint: incoming_fingerprint,
      operation: operation,
      state: "completed",
      completed_at: now
    )
    |> Repo.update!()

    Repo.delete_all(
      from(t in PrincipalToken,
        where:
          t.principal_id in ^Enum.uniq([source.principal_id, destination_id]) and
            t.context in ["session", "socket"]
      )
    )

    audit!(recovery_case.id, "completed", hd(approvals).approver_principal_id)

    %{
      case_reference: recovery_case.case_reference,
      state: "completed",
      operation: operation,
      incoming_subject_fingerprint: incoming_fingerprint
    }
  end

  defp validate_approval_operation!(recovery_case, command, now) do
    source = Repo.get!(ExternalIdentity, recovery_case.external_identity_id)
    oauth = live_proof!(recovery_case.id, "discord_oauth", now)
    destination = live_proof!(recovery_case.id, "destination_magic_link", now)
    operation = if oauth.subject == source.provider_subject, do: "transfer", else: "replacement"

    expected =
      approval_command(
        recovery_case,
        destination.principal_id,
        oauth.subject_fingerprint,
        operation
      )

    if Map.take(command, Map.keys(expected)) != expected,
      do: Repo.rollback(:invalid_recovery_operation)
  end

  defp approval_command(recovery_case, destination_id, incoming_fingerprint, operation),
    do: %{
      "version" => 1,
      "action" => "approve",
      "case_reference" => recovery_case.case_reference,
      "source_binding_fingerprint" => recovery_case.binding_fingerprint,
      "destination_principal_id" => destination_id,
      "incoming_subject_fingerprint" => incoming_fingerprint,
      "evidence_references" => recovery_case.evidence_references,
      "operation" => operation
    }

  defp live_proof!(case_id, kind, now \\ DateTime.utc_now()),
    do:
      Repo.one(
        from(p in IdentityRecoveryProof,
          where: p.recovery_case_id == ^case_id and p.kind == ^kind and p.expires_at > ^now,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:invalid_recovery_operation)

  defp lock_principals!(ids),
    do: ids |> Enum.uniq() |> Enum.sort() |> Enum.each(&DiscordSubjectLock.lock_principal!/1)

  defp lock_subjects!(subjects),
    do: subjects |> Enum.uniq() |> Enum.sort() |> Enum.each(&DiscordSubjectLock.lock!/1)

  defp audit!(case_id, action, actor_id),
    do:
      Repo.insert!(%IdentityRecoveryAuditEvent{
        recovery_case_id: case_id,
        action: action,
        actor_principal_id: actor_id
      })

  defp fail_on_conflict!(source, destination_id, incoming_subject) do
    if Repo.exists?(
         from(c in InvitationAcceptanceDiscordSubjectClaim,
           where: c.provider == "discord" and c.provider_subject == ^incoming_subject
         )
       ) or
         Repo.exists?(
           from(a in StagedAssignment,
             where:
               a.state in ["proposed", "approved"] and
                 (a.principal_id == ^destination_id or a.provider_subject == ^incoming_subject)
           )
         ) or
         Repo.exists?(
           from(i in ExternalIdentity,
             where:
               i.provider == "discord" and is_nil(i.retired_at) and i.id != ^source.id and
                 (i.principal_id == ^destination_id or i.provider_subject == ^incoming_subject)
           )
         ) do
      Repo.rollback(:invalid_recovery_operation)
    end
  end

  defp matching_proof?(proof, attrs) do
    proof.proof_digest == attrs.proof_digest and proof.subject == Map.get(attrs, :subject) and
      proof.subject_fingerprint == Map.get(attrs, :subject_fingerprint) and
      proof.principal_id == Map.get(attrs, :principal_id)
  end

  defp approval_matches?(approval, recovery_case, destination_id, incoming_fingerprint, operation) do
    approval.source_binding_fingerprint == recovery_case.binding_fingerprint and
      approval.destination_principal_id == destination_id and
      approval.incoming_subject_fingerprint == incoming_fingerprint and
      approval.evidence_references == recovery_case.evidence_references and
      approval.operation == operation
  end

  defp authorize_operator(principal_id) do
    if Repo.exists?(
         from(role in UserRole,
           where: role.principal_id == ^principal_id and role.role in ^@operator_roles
         )
       ), do: :ok, else: {:error, :unauthorized_operator}
  end

  defp exact_open_command(command) do
    valid? =
      MapSet.new(Map.keys(command)) ==
        MapSet.new(
          ~w(version action issued_at binding_id binding_fingerprint reporter_reference reason_code evidence_references actor_principal_id)
        ) and
        command["version"] == 1 and command["action"] == "open" and
        valid_uuid?(command["binding_id"]) and valid_uuid?(command["actor_principal_id"]) and
        command["reason_code"] in @reason_codes and is_binary(command["binding_fingerprint"]) and
        is_binary(command["reporter_reference"]) and is_list(command["evidence_references"]) and
        Enum.all?(command["evidence_references"], &(is_binary(&1) and byte_size(&1) > 0))

    if valid?, do: :ok, else: {:error, :invalid_recovery_command}
  end

  defp exact_approval_command(command) do
    valid? =
      MapSet.new(Map.keys(command)) ==
        MapSet.new(
          ~w(version action issued_at case_reference source_binding_fingerprint destination_principal_id incoming_subject_fingerprint evidence_references operation actor_principal_id)
        ) and
        command["version"] == 1 and command["action"] == "approve" and
        is_binary(command["case_reference"]) and is_binary(command["source_binding_fingerprint"]) and
        valid_uuid?(command["destination_principal_id"]) and
        is_binary(command["incoming_subject_fingerprint"]) and
        is_list(command["evidence_references"]) and
        command["operation"] in ["replacement", "transfer"] and
        valid_uuid?(command["actor_principal_id"])

    if valid?, do: :ok, else: {:error, :invalid_recovery_command}
  end

  defp fresh_command?(issued_at, now) when is_binary(issued_at) do
    with {:ok, issued_at, 0} <- DateTime.from_iso8601(issued_at),
         difference <- DateTime.diff(now, issued_at, :second),
         true <- difference >= 0 and difference <= @freshness_seconds do
      :ok
    else
      _ -> {:error, :stale_operator_authentication}
    end
  end

  defp fresh_command?(_, _), do: {:error, :stale_operator_authentication}

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp fingerprint(subject, key),
    do: :crypto.mac(:hmac, :sha256, key, subject) |> Base.encode16(case: :lower)

  defp proof_digest(subject, key), do: fingerprint("recovery-proof:" <> subject, key)

  defp usec_precision(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp case_reference, do: "DIR-" <> (Ecto.UUID.generate() |> String.upcase())

  defp transaction_result({:ok, receipt}), do: {:ok, receipt}
  defp transaction_result({:error, _reason}), do: {:error, :invalid_recovery_command}
end
