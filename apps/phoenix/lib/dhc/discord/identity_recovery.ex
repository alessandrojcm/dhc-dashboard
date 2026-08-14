defmodule Dhc.Discord.IdentityRecovery do
  @moduledoc """
  Runs the dual-controlled Discord identity recovery workflow.

  A signed, short-lived operator manifest opens and contains a case without
  exposing the Discord subject. A second, short-lived proof from the operator
  authentication issuer binds the named actor to that exact manifest digest and
  is consumed atomically with containment. Case-bound OAuth and destination
  magic-link proofs then establish the requested operation without creating an
  identity or Session. Two distinct authorized operators must sign the exact
  operation before one transaction retires the source binding, creates the
  destination binding, writes immutable history, and revokes every affected
  Session.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{DiscordSubjectLock, ExternalIdentity, PrincipalToken, UserRole}

  alias Dhc.Discord.{
    IdentityBindingHistory,
    IdentityRecoveryApproval,
    IdentityRecoveryCase,
    IdentityRecoveryOperatorProofUse,
    IdentityRecoveryProof,
    SignedManifest,
    StagedAssignment,
    SubjectFingerprint
  }

  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo

  @operator_roles ~w(admin president)
  @reason_codes ~w(promoted_binding replacement_request)
  @freshness_seconds 300
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @reporter_reference_pattern ~r/\A(?:support-case|ticket):[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z/
  @evidence_reference_pattern ~r/\A(?:evidence|attachment|ticket):[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z/

  @terminal_states ~w(failed cancelled expired)

  def active_case?(case_reference) when is_binary(case_reference) do
    Repo.exists?(
      from(recovery_case in IdentityRecoveryCase,
        where: recovery_case.case_reference == ^case_reference and recovery_case.state == "open"
      )
    )
  end

  def active_case?(_), do: false

  @doc "Issues a destination proof credential bound to one exact active case."
  def deliver_destination_proof(case_reference, email, magic_link_url_fun)
      when is_binary(case_reference) and is_binary(email) and
             is_function(magic_link_url_fun, 1) do
    case Repo.one(
           from(recovery_case in IdentityRecoveryCase,
             where:
               recovery_case.case_reference == ^case_reference and
                 recovery_case.state == "open",
             select: recovery_case.id
           )
         ) do
      nil -> {:ok, :sent}
      case_id -> Auth.deliver_identity_recovery_link(email, case_id, magic_link_url_fun)
    end
  end

  def deliver_destination_proof(_, _, _), do: {:ok, :sent}

  @doc "Records a callback-verified OAuth subject as a short-lived recovery proof. It never links an identity or mints a Session."
  def record_discord_oauth_proof(
        case_reference,
        claims,
        fingerprint_key,
        now \\ DateTime.utc_now()
      )

  def record_discord_oauth_proof(
        case_reference,
        %{"sub" => subject},
        fingerprint_key,
        now
      )
      when is_binary(case_reference) and is_binary(subject) and subject != "" and
             is_binary(fingerprint_key) and is_struct(now, DateTime) do
    record_proof(
      case_reference,
      "discord_oauth",
      %{subject: subject, subject_fingerprint: fingerprint(subject, fingerprint_key)},
      proof_digest(subject, fingerprint_key),
      now
    )
  end

  def record_discord_oauth_proof(_, _, _, _), do: {:error, :invalid_recovery_proof}

  @doc "Consumes a case-bound destination credential as proof only; it never establishes a Session."
  def record_magic_link_proof(case_reference, token, now \\ DateTime.utc_now())

  def record_magic_link_proof(case_reference, token, now)
      when is_binary(case_reference) and is_binary(token) and is_struct(now, DateTime) do
    now = usec_precision(now)

    Repo.transaction(fn ->
      recovery_case =
        Repo.one(
          from(c in IdentityRecoveryCase,
            where: c.case_reference == ^case_reference,
            lock: "FOR UPDATE"
          )
        )

      if is_nil(recovery_case) or recovery_case.state != "open",
        do: Repo.rollback(:invalid_recovery_proof)

      with {:ok, query} <-
             PrincipalToken.verify_identity_recovery_token_query(token, recovery_case.id) do
        case Repo.one(query |> lock("FOR UPDATE")) do
          {principal, token_row} ->
            Repo.delete!(token_row)

            record_proof_locked(
              recovery_case,
              "destination_magic_link",
              %{principal_id: principal.id},
              token |> PrincipalToken.hash_token() |> Base.encode16(case: :lower),
              now
            )

          nil ->
            Repo.rollback(:invalid_recovery_proof)
        end
      else
        _ -> Repo.rollback(:invalid_recovery_proof)
      end
    end)
    |> transaction_result()
  end

  def record_magic_link_proof(_, _, _), do: {:error, :invalid_recovery_proof}

  @doc "Accepts an independently signed administrator approval of the exact proof-bound operation."
  def approve_signed(envelope, options) when is_map(options) do
    with {:ok, actor_id, command, digest} <-
           verify_approver(envelope, Map.get(options, :approver_public_keys, %{})),
         :ok <- exact_approval_command(command),
         :ok <- fresh_command?(command["issued_at"], Map.get(options, :now, DateTime.utc_now())),
         :ok <- authorize_operator(actor_id) do
      approve(command, actor_id, digest, Map.get(options, :now, DateTime.utc_now()))
    end
  end

  def approve_signed(_, _), do: {:error, :invalid_recovery_command}

  def complete(case_reference, fingerprint_key)
      when is_binary(case_reference) and is_binary(fingerprint_key) do
    case Repo.transaction(fn -> complete_locked(case_reference, fingerprint_key) end) do
      {:ok, {result, principal_ids}} ->
        Enum.each(principal_ids, &DhcWeb.UserSocket.disconnect/1)
        {:ok, result}

      {:error, _reason} ->
        {:error, :invalid_recovery_command}
    end
  rescue
    Postgrex.Error -> {:error, :invalid_recovery_operation}
    Ecto.ConstraintError -> {:error, :invalid_recovery_operation}
  end

  def complete(_, _), do: {:error, :invalid_recovery_operation}

  @doc "Closes an unresolved case while preserving containment and immutable evidence."
  def close_signed(envelope, options) when is_map(envelope) and is_map(options) do
    with {:ok, manifest_keys} <- required_keyring(options, :manifest_keys),
         {:ok, command, _digest, signer} <- SignedManifest.verify(envelope, manifest_keys),
         :ok <- exact_close_command(command),
         :ok <- signed_by_actor(command, signer),
         :ok <- fresh_command?(command["issued_at"], Map.get(options, :now, DateTime.utc_now())),
         :ok <- authorize_operator(signer) do
      close(command)
    end
  end

  def close_signed(_, _), do: {:error, :invalid_recovery_command}

  def open_signed(manifest_envelope, proof_envelope, options)
      when is_map(manifest_envelope) and is_map(proof_envelope) and is_map(options) do
    with {:ok, manifest_keys} <- required_keyring(options, :manifest_keys),
         {:ok, proof_keys} <- required_keyring(options, :operator_proof_keys),
         {:ok, fingerprint_key} <- required_option(options, :fingerprint_key),
         {:ok, command, manifest_digest, manifest_signer} <-
           SignedManifest.verify(manifest_envelope, manifest_keys),
         :ok <- exact_open_command(command),
         :ok <- signed_by_actor(command, manifest_signer),
         {:ok, proof, proof_digest, proof_signer} <-
           SignedManifest.verify(proof_envelope, proof_keys),
         :ok <- exact_operator_proof(proof),
         :ok <- signed_by_actor(proof, proof_signer),
         :ok <- proof_matches_command(proof, command, manifest_digest),
         :ok <- fresh?(command["issued_at"], Map.get(options, :now, DateTime.utc_now())),
         :ok <- fresh?(proof["issued_at"], Map.get(options, :now, DateTime.utc_now())) do
      open(command, manifest_digest, proof_digest, fingerprint_key)
    else
      {:error, :stale_operator_authentication} = error -> error
      _error -> {:error, :invalid_recovery_command}
    end
  end

  def open_signed(_, _, _), do: {:error, :invalid_recovery_command}

  defp open(command, manifest_digest, proof_digest, fingerprint_key) do
    if Repo.in_transaction?() do
      {:error, :nested_transaction}
    else
      case lookup_identity(command["binding_id"]) do
        nil ->
          {:error, :invalid_recovery_command}

        identity ->
          open_identity(identity, command, manifest_digest, proof_digest, fingerprint_key)
      end
    end
  end

  defp lookup_identity(binding_id) do
    Repo.one(
      from(identity in ExternalIdentity,
        where: identity.id == ^binding_id and identity.provider == "discord"
      )
    )
  end

  defp open_identity(identity, command, manifest_digest, proof_digest, fingerprint_key) do
    Repo.transaction(fn ->
      DiscordSubjectLock.lock_principal!(identity.principal_id)
      DiscordSubjectLock.lock!(identity.provider_subject)

      locked_identity =
        Repo.one(
          from(candidate in ExternalIdentity,
            where:
              candidate.id == ^identity.id and candidate.id == ^command["binding_id"] and
                candidate.provider == "discord" and is_nil(candidate.retired_at) and
                candidate.principal_id == ^identity.principal_id and
                candidate.provider_subject == ^identity.provider_subject,
            lock: "FOR UPDATE"
          )
        )

      if is_nil(locked_identity), do: Repo.rollback(:invalid_recovery_command)
      authorize_operator_locked!(command["actor_principal_id"])

      expected_fingerprint =
        SubjectFingerprint.generate(locked_identity.provider_subject, fingerprint_key)

      unless Plug.Crypto.secure_compare(
               command["binding_fingerprint"],
               expected_fingerprint
             ),
             do: Repo.rollback(:invalid_recovery_command)

      existing_case =
        Repo.one(
          from(recovery_case in IdentityRecoveryCase,
            where:
              recovery_case.external_identity_id == ^locked_identity.id and
                recovery_case.state == "open",
            lock: "FOR UPDATE"
          )
        )

      if existing_case do
        {receipt(existing_case), nil}
      else
        open_new_case(
          locked_identity,
          command,
          manifest_digest,
          proof_digest,
          expected_fingerprint
        )
      end
    end)
    |> transaction_result()
    |> disconnect_after_commit()
  rescue
    Postgrex.Error -> {:error, :invalid_recovery_command}
    Ecto.ConstraintError -> {:error, :invalid_recovery_command}
  end

  defp open_new_case(
         identity,
         command,
         manifest_digest,
         proof_digest,
         expected_fingerprint
       ) do
    previously_contained? = terminal_containment?(identity.id)

    if not is_nil(identity.sign_in_disabled_at) and not previously_contained?,
      do: Repo.rollback(:invalid_recovery_command)

    now = DateTime.utc_now()

    recovery_case =
      %IdentityRecoveryCase{
        external_identity_id: identity.id,
        case_reference: case_reference(),
        state: "open",
        binding_fingerprint: expected_fingerprint,
        actor_principal_id: command["actor_principal_id"],
        opened_at: now
      }
      |> IdentityRecoveryCase.open_changeset(%{
        reason_code: command["reason_code"],
        reporter_reference: command["reporter_reference"],
        evidence_references: command["evidence_references"]
      })
      |> Repo.insert()
      |> case do
        {:ok, recovery_case} -> recovery_case
        {:error, _changeset} -> Repo.rollback(:invalid_recovery_command)
      end

    containment_count =
      Repo.update_all(
        from(external_identity in ExternalIdentity,
          where:
            external_identity.id == ^identity.id and
              is_nil(external_identity.sign_in_disabled_at)
        ),
        set: [sign_in_disabled_at: now]
      )

    case containment_count do
      {1, _rows} -> :ok
      {0, _rows} when previously_contained? -> :ok
      _other -> Repo.rollback(:invalid_recovery_command)
    end

    Repo.delete_all(
      from(token in PrincipalToken,
        where:
          token.principal_id == ^identity.principal_id and
            token.context in ["session", "socket"]
      )
    )

    case Repo.insert(%IdentityRecoveryOperatorProofUse{
           proof_digest: proof_digest,
           manifest_digest: manifest_digest,
           actor_principal_id: command["actor_principal_id"],
           recovery_case_id: recovery_case.id,
           consumed_at: now
         }) do
      {:ok, _proof_use} -> {receipt(recovery_case), identity.principal_id}
      {:error, _changeset} -> Repo.rollback(:invalid_recovery_command)
    end
  end

  defp authorize_operator_locked!(principal_id) do
    role =
      UserRole
      |> where(
        [candidate],
        candidate.principal_id == ^principal_id and candidate.role in ^@operator_roles
      )
      |> order_by([candidate], candidate.role)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(role), do: Repo.rollback(:unauthorized_operator)
  end

  defp terminal_containment?(external_identity_id) do
    Repo.exists?(
      from(recovery_case in IdentityRecoveryCase,
        where:
          recovery_case.external_identity_id == ^external_identity_id and
            recovery_case.state in ^@terminal_states
      )
    )
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

  defp record_proof(case_reference, kind, attrs, digest, now) do
    now = usec_precision(now)

    Repo.transaction(fn -> record_proof_locked(case_reference, kind, attrs, digest, now) end)
    |> transaction_result()
  end

  defp record_proof_locked(case_reference, kind, attrs, digest, now)
       when is_binary(case_reference) do
    recovery_case =
      Repo.one(
        from(c in IdentityRecoveryCase,
          where: c.case_reference == ^case_reference,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(recovery_case), do: Repo.rollback(:invalid_recovery_proof)
    record_proof_locked(recovery_case, kind, attrs, digest, now)
  end

  defp record_proof_locked(%IdentityRecoveryCase{} = recovery_case, kind, attrs, digest, now) do
    if recovery_case.state != "open", do: Repo.rollback(:invalid_recovery_proof)

    expires_at = DateTime.add(now, @freshness_seconds, :second)

    existing =
      Repo.one(
        from(p in IdentityRecoveryProof,
          where: p.recovery_case_id == ^recovery_case.id and p.kind == ^kind,
          order_by: [desc: p.attempt],
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

    proof_attrs =
      Map.merge(attrs, %{
        recovery_case_id: recovery_case.id,
        kind: kind,
        proof_digest: digest,
        attempt: if(existing, do: existing.attempt + 1, else: 1),
        expires_at: expires_at
      })

    cond do
      is_nil(existing) ->
        Repo.insert!(struct(IdentityRecoveryProof, proof_attrs))
        receipt(recovery_case)

      matching_proof?(existing, proof_attrs) and DateTime.after?(existing.expires_at, now) ->
        receipt(recovery_case)

      DateTime.after?(existing.expires_at, now) ->
        Repo.rollback(:invalid_recovery_proof)

      true ->
        Repo.insert!(struct(IdentityRecoveryProof, proof_attrs))
        receipt(recovery_case)
    end
  end

  defp approve(command, actor_id, digest, now) do
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

      oauth = live_proof!(recovery_case.id, "discord_oauth", now)
      destination = live_proof!(recovery_case.id, "destination_magic_link", now)

      current_approvals =
        Repo.all(
          from(a in IdentityRecoveryApproval,
            where:
              a.recovery_case_id == ^recovery_case.id and
                a.discord_oauth_proof_id == ^oauth.id and
                a.destination_magic_link_proof_id == ^destination.id and
                a.expires_at > ^now,
            lock: "FOR UPDATE"
          )
        )

      existing = Enum.find(current_approvals, &(&1.approver_principal_id == actor_id))

      cond do
        existing && existing.approval_digest == digest ->
          receipt(recovery_case)

        existing ->
          Repo.rollback(:invalid_recovery_operation)

        length(current_approvals) >= 2 ->
          Repo.rollback(:invalid_recovery_operation)

        true ->
          attempt =
            Repo.one(
              from(a in IdentityRecoveryApproval,
                where:
                  a.recovery_case_id == ^recovery_case.id and
                    a.approver_principal_id == ^actor_id,
                select: coalesce(max(a.attempt), 0)
              )
            ) + 1

          %IdentityRecoveryApproval{}
          |> Ecto.Changeset.change(%{
            recovery_case_id: recovery_case.id,
            approver_principal_id: actor_id,
            discord_oauth_proof_id: oauth.id,
            destination_magic_link_proof_id: destination.id,
            attempt: attempt,
            approval_digest: digest,
            source_binding_fingerprint: command["source_binding_fingerprint"],
            destination_principal_id: command["destination_principal_id"],
            incoming_subject_fingerprint: command["incoming_subject_fingerprint"],
            evidence_references: command["evidence_references"],
            operation: command["operation"],
            expires_at: DateTime.add(now, @freshness_seconds, :second)
          })
          |> Repo.insert!()

          receipt(recovery_case)
      end
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

    completion_time = DateTime.utc_now()

    approvals =
      Repo.all(
        from(a in IdentityRecoveryApproval,
          where:
            a.recovery_case_id == ^recovery_case.id and
              a.discord_oauth_proof_id == ^oauth.id and
              a.destination_magic_link_proof_id == ^destination_proof.id and
              a.expires_at > ^completion_time,
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
    now = completion_time
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
            (t.context in ["session", "socket", "login"] or
               like(t.context, "identity_recovery:%"))
      )
    )

    {%{
       case_reference: recovery_case.case_reference,
       state: "completed",
       operation: operation,
       incoming_subject_fingerprint: incoming_fingerprint
     }, Enum.uniq([source.principal_id, destination_id])}
  end

  defp close(command) do
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

      now = DateTime.utc_now()

      recovery_case
      |> Ecto.Changeset.change(
        state: command["outcome"],
        terminal_at: now,
        terminal_reason_code: command["reason_code"],
        terminal_actor_principal_id: command["actor_principal_id"]
      )
      |> Repo.update!()

      context = PrincipalToken.identity_recovery_context(recovery_case.id)
      Repo.delete_all(from(t in PrincipalToken, where: t.context == ^context))

      recovery_case
      |> Map.put(:state, command["outcome"])
      |> receipt()
    end)
    |> transaction_result()
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
          order_by: [desc: p.attempt],
          limit: 1,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:invalid_recovery_operation)

  defp lock_principals!(ids),
    do: ids |> Enum.uniq() |> Enum.sort() |> Enum.each(&DiscordSubjectLock.lock_principal!/1)

  defp lock_subjects!(subjects),
    do: subjects |> Enum.uniq() |> Enum.sort() |> Enum.each(&DiscordSubjectLock.lock!/1)

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
      exact_keys?(
        command,
        ~w(version action issued_at binding_id binding_fingerprint reporter_reference reason_code evidence_references actor_principal_id)
      ) and
        command["version"] == 1 and command["action"] == "open" and
        valid_uuid?(command["binding_id"]) and valid_uuid?(command["actor_principal_id"]) and
        command["reason_code"] in @reason_codes and
        SubjectFingerprint.valid?(command["binding_fingerprint"]) and
        valid_reporter_reference?(command["reporter_reference"]) and
        valid_evidence_references?(command["evidence_references"])

    if valid?, do: :ok, else: {:error, :invalid_recovery_command}
  end

  defp exact_approval_command(command) do
    valid? =
      MapSet.new(Map.keys(command)) ==
        MapSet.new(
          ~w(version action issued_at case_reference source_binding_fingerprint destination_principal_id incoming_subject_fingerprint evidence_references operation)
        ) and
        command["version"] == 1 and command["action"] == "approve" and
        is_binary(command["case_reference"]) and is_binary(command["source_binding_fingerprint"]) and
        valid_uuid?(command["destination_principal_id"]) and
        is_binary(command["incoming_subject_fingerprint"]) and
        is_list(command["evidence_references"]) and
        command["operation"] in ["replacement", "transfer"]

    if valid?, do: :ok, else: {:error, :invalid_recovery_command}
  end

  defp exact_close_command(command) do
    valid? =
      MapSet.new(Map.keys(command)) ==
        MapSet.new(
          ~w(version action issued_at case_reference outcome reason_code actor_principal_id)
        ) and
        command["version"] == 1 and command["action"] == "close" and
        is_binary(command["case_reference"]) and command["outcome"] in @terminal_states and
        is_binary(command["reason_code"]) and byte_size(command["reason_code"]) in 1..128 and
        valid_uuid?(command["actor_principal_id"])

    if valid?, do: :ok, else: {:error, :invalid_recovery_command}
  end

  defp exact_operator_proof(proof) do
    valid? =
      exact_keys?(
        proof,
        ~w(version action issued_at manifest_digest actor_principal_id nonce)
      ) and
        proof["version"] == 1 and proof["action"] == "authorize_identity_recovery" and
        valid_uuid?(proof["actor_principal_id"]) and valid_uuid?(proof["nonce"]) and
        is_binary(proof["manifest_digest"]) and
        String.match?(proof["manifest_digest"], @digest_pattern)

    if valid?, do: :ok, else: {:error, :invalid_recovery_command}
  end

  defp proof_matches_command(proof, command, manifest_digest) do
    if proof["actor_principal_id"] == command["actor_principal_id"] and
         proof["manifest_digest"] == manifest_digest,
       do: :ok,
       else: {:error, :invalid_recovery_command}
  end

  defp signed_by_actor(command, signer) do
    if command["actor_principal_id"] == signer,
      do: :ok,
      else: {:error, :invalid_recovery_command}
  end

  defp exact_keys?(value, keys) when is_map(value),
    do: MapSet.new(Map.keys(value)) == MapSet.new(keys)

  defp exact_keys?(_value, _keys), do: false

  defp valid_reporter_reference?(value) when is_binary(value),
    do: String.match?(value, @reporter_reference_pattern)

  defp valid_reporter_reference?(_value), do: false

  defp valid_evidence_references?(references)
       when is_list(references) and length(references) in 1..10 do
    Enum.all?(references, fn reference ->
      is_binary(reference) and String.match?(reference, @evidence_reference_pattern)
    end)
  end

  defp valid_evidence_references?(_references), do: false

  defp verify_approver(envelope, public_keys) when is_map(public_keys) do
    if valid_approver_keyring?(public_keys) do
      Enum.find_value(public_keys, {:error, :invalid_manifest_signature}, fn
        {principal_id, public_key} ->
          case SignedManifest.verify_ed25519(envelope, public_key) do
            {:ok, command, digest} -> {:ok, principal_id, command, digest}
            {:error, _reason} -> false
          end
      end)
    else
      {:error, :invalid_manifest_signature}
    end
  end

  defp verify_approver(_, _), do: {:error, :invalid_manifest_signature}

  defp valid_approver_keyring?(public_keys) do
    keys = Map.values(public_keys)

    map_size(public_keys) > 0 and
      Enum.all?(public_keys, fn {principal_id, public_key} ->
        valid_uuid?(principal_id) and is_binary(public_key) and byte_size(public_key) == 32
      end) and length(Enum.uniq(keys)) == length(keys)
  end

  defp fresh?(issued_at, now) when is_binary(issued_at) do
    with {:ok, issued_at, 0} <- DateTime.from_iso8601(issued_at),
         difference <- DateTime.diff(now, issued_at, :second),
         true <- difference >= 0 and difference <= @freshness_seconds do
      :ok
    else
      _ -> {:error, :stale_operator_authentication}
    end
  end

  defp fresh?(_, _), do: {:error, :stale_operator_authentication}

  defp fresh_command?(issued_at, now), do: fresh?(issued_at, now)

  defp required_option(options, key) do
    case Map.get(options, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_recovery_command}
    end
  end

  defp required_keyring(options, key) do
    case Map.get(options, key) do
      value when is_map(value) and map_size(value) > 0 -> {:ok, value}
      _value -> {:error, :invalid_recovery_command}
    end
  end

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp fingerprint(subject, key), do: SubjectFingerprint.generate(subject, key)

  defp proof_digest(subject, key), do: fingerprint("recovery-proof:" <> subject, key)

  defp usec_precision(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp case_reference, do: "DIR-" <> (Ecto.UUID.generate() |> String.upcase())

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, :unauthorized_operator}), do: {:error, :unauthorized_operator}
  defp transaction_result({:error, _reason}), do: {:error, :invalid_recovery_command}

  defp disconnect_after_commit({:ok, {receipt, nil}}), do: {:ok, receipt}

  defp disconnect_after_commit({:ok, {receipt, principal_id}}) do
    DhcWeb.UserSocket.disconnect(principal_id)
    {:ok, receipt}
  end

  defp disconnect_after_commit(error), do: error
end
