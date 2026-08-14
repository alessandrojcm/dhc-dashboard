defmodule Dhc.Discord.IdentityRecovery do
  @moduledoc """
  Opens separately authenticated Discord identity recovery cases.

  A signed, short-lived operator manifest is intentionally the only entry point.
  It contains a binding UUID and HMAC fingerprint, never a Discord subject or
  mutable Discord profile data. Opening a case atomically contains sign-in and
  revokes the affected Principal's sessions without changing identity ownership.
  """

  import Ecto.Query

  alias Dhc.Auth.{ExternalIdentity, UserRole}
  alias Dhc.Discord.{IdentityRecoveryAuditEvent, IdentityRecoveryCase, SignedManifest}
  alias Dhc.Repo

  @operator_roles ~w(admin president)
  @reason_codes ~w(promoted_binding replacement_request)
  @freshness_seconds 300

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
            where: identity.id == ^command["binding_id"] and identity.provider == "discord",
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

  defp case_reference, do: "DIR-" <> (Ecto.UUID.generate() |> String.upcase())

  defp transaction_result({:ok, receipt}), do: {:ok, receipt}
  defp transaction_result({:error, _reason}), do: {:error, :invalid_recovery_command}
end
