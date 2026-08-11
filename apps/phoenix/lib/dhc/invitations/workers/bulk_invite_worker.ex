defmodule Dhc.Invitations.BulkInviteWorker do
  @moduledoc """
  Oban worker that processes bulk member invitations.

  Migrates the `bulk_invite_with_subscription` Deno edge function into the
  Phoenix/Oban runtime. The Phoenix API layer is responsible for authorising
  admin-level access before enqueueing this worker.

  ## ALE-162 — issue time is side-effect free

  ADR 0010 fixes that the Authentication Principal is born inside Invitation
  Acceptance, not at issue. This worker now performs **only** the issue-time
  work for each invite:

    * mint a fresh Phoenix UUID for `invitation.prospective_principal_id` (the eventual
      Principal id);
    * insert the pending `invitations` row carrying `email`, `date_of_birth`,
      `expires_at` (7 days), `created_by_principal_id`, and `invitation_type`;
    * enqueue the `inviteMember` email;
    * if the invite came from a waitlist, mark the waitlist entry `invited`.

  It no longer calls the Supabase admin API, creates a Stripe customer, or
  inserts a `user_profiles` row. Principal, profile, and Membership
  creation happen during acceptance. The previous per-invite Supabase-Auth /
  Stripe / profile-creation failure modes no longer exist at issue time; the
  remaining failure modes are DB insert errors and email-enqueue errors.

  ## Job args

    * `invites` — list of invite maps or waitlist IDs. Invite maps require
      `firstName`, `lastName`, `email`, `phoneNumber`, and `dateOfBirth`.
    * `user` — admin context map containing `id` and optionally `email`.

  The worker intentionally records per-invite failures and continues processing
  the rest of the batch. It only returns an error for invalid job args or an
  unrecoverable failure while issuing an Invitation. Batch summary failures
  are logged but do not fail this job, so completed per-Invitation work is
  never replayed.
  """

  use Oban.Worker, queue: :invitations, max_attempts: 3

  require Logger

  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Invitations.Repository
  alias Dhc.Repo

  @invite_email_template "inviteMember"
  @default_app_url "http://localhost:5173"

  @impl Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(attempt, 4) + 15)

  @impl Worker
  def perform(%Oban.Job{args: args} = job) do
    ctx = job_log_context(job)

    with :ok <- validate_args(args),
         {:ok, results} <- process_invites(args, ctx) do
      Logger.info(
        "[bulk-invite-worker] Completed bulk invitation batch",
        Keyword.merge(ctx,
          created_by: get_in(args, ["user", "id"]),
          total_count: length(results),
          success_count: Enum.count(results, & &1.success),
          failure_count: Enum.count(results, &(not &1.success))
        )
      )

      :ok
    else
      {:error, reason} = error ->
        # Pass the reason as a structured keyword -> string map so Sentry's PII
        # filter doesn't strip it (inspect/1 on error tuples can contain email
        # addresses, which triggers the [Filtered] redaction in Sentry's UI).
        reason_map = reason_to_map(reason)

        Sentry.capture_message("Bulk invite worker failed",
          level: :error,
          extra: %{
            reason: reason_map,
            created_by: get_in(args, ["user", "id"]),
            oban_job_id: ctx[:oban_job_id],
            oban_attempt: ctx[:oban_attempt],
            oban_queue: ctx[:oban_queue],
            oban_worker: ctx[:oban_worker]
          }
        )

        Logger.error(
          "[bulk-invite-worker] Job failed: #{inspect(reason)}",
          Keyword.merge(ctx,
            created_by: get_in(args, ["user", "id"]),
            reason: format_reason(reason)
          )
        )

        error
    end
  end

  defp validate_args(args) do
    errors =
      []
      |> validate_required(args, "invites")
      |> validate_invites(args)
      |> validate_required(args, "user")
      |> validate_user(args)

    case errors do
      [] -> :ok
      errors -> {:error, {:validation, Enum.reverse(errors)}}
    end
  end

  defp validate_required(errors, args, field) do
    if is_nil(args[field]) or args[field] == "", do: ["missing #{field}" | errors], else: errors
  end

  defp validate_invites(errors, %{"invites" => invites})
       when is_list(invites) and length(invites) > 0,
       do: errors

  defp validate_invites(errors, %{"invites" => _invites}),
    do: ["invites must be a non-empty list" | errors]

  defp validate_invites(errors, _args), do: errors

  defp validate_user(errors, %{"user" => %{"id" => id}}) when is_binary(id) and id != "",
    do: errors

  defp validate_user(errors, %{"user" => _user}), do: ["user.id is required" | errors]
  defp validate_user(errors, _args), do: errors

  defp process_invites(%{"invites" => invites, "user" => %{"id" => created_by_id}}, ctx) do
    start_time = System.monotonic_time(:millisecond)

    results =
      invites
      |> Enum.with_index()
      |> Enum.map(fn {invite, index} -> process_one_invite(invite, index, created_by_id, ctx) end)

    finalize_batch(results, created_by_id, ctx)

    processing_time_ms = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "[bulk-invite-worker] Stored invitation processing results",
      Keyword.merge(ctx,
        created_by: created_by_id,
        processing_time_ms: processing_time_ms
      )
    )

    {:ok, results}
  end

  defp finalize_batch(results, created_by_id, ctx) do
    with :ok <- Repository.store_processing_results(results, created_by_id),
         :ok <- Repository.create_processing_notification(results, created_by_id) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "[bulk-invite-worker] Batch finalization failed after invitation issue completed",
          Keyword.merge(ctx, created_by: created_by_id, reason: format_reason(reason))
        )

        :ok
    end
  end

  defp process_one_invite(invite, index, created_by_id, ctx) do
    with {:ok, invite_data} <- resolve_invite_data(invite),
         invite_data <- put_issue_key(invite_data, issue_key(ctx, index)),
         {:ok, result} <- create_invitation_pipeline(invite, invite_data, created_by_id, ctx) do
      result
    else
      {:error, reason} ->
        email = invite_email(invite)
        reason_map = reason_to_map(reason)

        Sentry.capture_message("Bulk invitation failed",
          level: :error,
          extra: %{
            reason: reason_map,
            invite_email: email,
            oban_job_id: ctx[:oban_job_id],
            oban_attempt: ctx[:oban_attempt],
            oban_queue: ctx[:oban_queue],
            oban_worker: ctx[:oban_worker]
          }
        )

        Logger.error(
          "[bulk-invite-worker] Failed to process invitation",
          Keyword.merge(ctx, email: email, reason: format_reason(reason))
        )

        %{email: email || "unknown", success: false, error: inspect(reason)}
    end
  end

  defp resolve_invite_data(waitlist_id) when is_binary(waitlist_id) do
    Repository.get_waitlist_invite_data(waitlist_id)
  end

  defp resolve_invite_data(invite) when is_map(invite) do
    required = ~w(firstName lastName email phoneNumber dateOfBirth)
    missing = Enum.filter(required, &(is_nil(invite[&1]) or invite[&1] == ""))

    if missing == [], do: {:ok, invite}, else: {:error, {:invalid_invite, missing}}
  end

  defp resolve_invite_data(_invite), do: {:error, :invalid_invite_shape}

  defp create_invitation_pipeline(original_invite, invite_data, created_by_id, ctx) do
    # ALE-162 (ADR 0010): issue time is one insert. No Supabase admin call,
    # no Stripe customer, no user_profiles row. Acceptance materializes the
    # Principal + record set; acceptance creates the Stripe customer.
    issue_key = get_in(invite_data, ["metadata", "issue_key"])

    case Repository.invitation_id_for_issue_key(issue_key) do
      {:ok, invitation_id} ->
        {:ok, invitation_result(invite_data, invitation_id)}

      :not_found ->
        Repo.transaction(fn ->
          with {:ok, invitation_id} <-
                 Repository.create_invitation_record(original_invite, invite_data, created_by_id),
               :ok <- enqueue_invitation_email(invite_data, invitation_id),
               :ok <- maybe_update_waitlist(original_invite) do
            Logger.info(
              "[bulk-invite-worker] Processed invitation",
              Keyword.merge(ctx,
                email: invite_data["email"],
                invitation_id: invitation_id
              )
            )

            invitation_result(invite_data, invitation_id)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp invitation_result(invite_data, invitation_id) do
    %{email: invite_data["email"], success: true, invitationId: invitation_id}
  end

  defp issue_key(ctx, index), do: "bulk-invite:#{ctx[:oban_job_id] || "unpersisted"}:#{index}"

  defp put_issue_key(invite_data, issue_key) do
    metadata = Map.get(invite_data, "metadata") || %{}
    Map.put(invite_data, "metadata", Map.put(metadata, "issue_key", issue_key))
  end

  defp enqueue_invitation_email(invite_data, invitation_id) do
    invitation_link = invitation_link(invite_data, invitation_id)

    args = %{
      "email" => invite_data["email"],
      "transactional_id" => @invite_email_template,
      "data_variables" => %{
        "firstName" => invite_data["firstName"],
        "lastName" => invite_data["lastName"],
        "invitationLink" => invitation_link
      }
    }

    case Oban.insert(EmailWorker.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:email_enqueue, reason}}
    end
  end

  defp maybe_update_waitlist(waitlist_id) when is_binary(waitlist_id) do
    Repository.mark_waitlist_invited(waitlist_id)
  end

  defp maybe_update_waitlist(_invite), do: :ok

  defp invitation_link(invite_data, invitation_id) do
    app_url = Application.get_env(:dhc, :app_url, @default_app_url)

    app_url
    |> URI.merge("/members/signup/#{invitation_id}")
    |> Map.put(
      :query,
      URI.encode_query(%{
        "dateOfBirth" => Repository.date_string(invite_data["dateOfBirth"]),
        "email" => invite_data["email"]
      })
    )
    |> URI.to_string()
  end

  defp invite_email(%{"email" => email}), do: email
  defp invite_email(_invite), do: nil

  defp job_log_context(%Oban.Job{} = job) do
    [
      oban_job_id: job.id,
      oban_attempt: job.attempt,
      oban_queue: job.queue,
      oban_worker: job.worker
    ]
  end

  # Convert an error reason into a plain string-keyed map so Sentry's PII
  # filter doesn't redact it. inspect/1 on tuples that contain emails (e.g.
  # {:email_enqueue, %{email: "..."}}) triggers Sentry's [Filtered] redaction.
  # We stringify atoms and keep values as strings; nested maps are flattened
  # one level. Anything we can't structurize falls back to inspect/1.
  defp reason_to_map(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.into(%{}, fn {value, idx} -> {Integer.to_string(idx), stringify(value)} end)
  end

  defp reason_to_map(reason) when is_map(reason) do
    Enum.into(reason, %{}, fn {k, v} -> {stringify(k), stringify(v)} end)
  end

  defp reason_to_map(reason) when is_list(reason) do
    Enum.into(reason, %{}, fn v -> {stringify(v), true} end)
  end

  defp reason_to_map(reason), do: %{"value" => stringify(reason)}

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_number(value), do: to_string(value)
  defp stringify(value), do: inspect(value)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason({:validation, errors}), do: "validation: #{Enum.join(errors, ", ")}"
  defp format_reason(other), do: inspect(other)
end
