defmodule Dhc.Invitations.BulkInviteWorker do
  @moduledoc """
  Oban worker that processes bulk member invitations.

  Migrates the `bulk_invite_with_subscription` Deno edge function into the
  Phoenix/Oban runtime. The Phoenix API layer is responsible for authorising
  admin-level access before enqueueing this worker.

  ## Job args

    * `invites` — list of invite maps or waitlist IDs. Invite maps require
      `firstName`, `lastName`, `email`, `phoneNumber`, and `dateOfBirth`.
    * `user` — admin context map containing `id` and optionally `email`.

  The worker intentionally records per-invite failures and continues processing
  the rest of the batch. It only returns an error for invalid job args or an
  unrecoverable failure to write the final processing log/notification.
  """

  use Oban.Worker, queue: :invitations, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Repo
  alias Dhc.Stripe.Client, as: StripeClient

  @invite_email_template "inviteMember"
  @default_app_url "http://localhost:5173"

  @impl Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(attempt, 4) + 15)

  @impl Worker
  def perform(%Oban.Job{args: args}) do
    with :ok <- validate_args(args),
         {:ok, results} <- process_invites(args) do
      Logger.info("[bulk-invite-worker] Completed bulk invitation batch",
        created_by: get_in(args, ["user", "id"]),
        total_count: length(results),
        success_count: Enum.count(results, & &1.success),
        failure_count: Enum.count(results, &(not &1.success))
      )

      :ok
    else
      {:error, reason} = error ->
        Sentry.capture_message("Bulk invite worker failed",
          level: :error,
          extra: %{reason: inspect(reason)}
        )

        Logger.error("[bulk-invite-worker] Job failed: #{inspect(reason)}")
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

  defp process_invites(%{"invites" => invites, "user" => %{"id" => created_by_id}}) do
    start_time = System.monotonic_time(:millisecond)

    results = Enum.map(invites, &process_one_invite(&1, created_by_id))

    with :ok <- store_processing_results(results, created_by_id),
         :ok <- create_notification(results, created_by_id) do
      processing_time_ms = System.monotonic_time(:millisecond) - start_time

      Logger.info("[bulk-invite-worker] Stored invitation processing results",
        created_by: created_by_id,
        processing_time_ms: processing_time_ms
      )

      {:ok, results}
    end
  end

  defp process_one_invite(invite, created_by_id) do
    with {:ok, invite_data} <- resolve_invite_data(invite),
         {:ok, result} <- create_invitation_pipeline(invite, invite_data, created_by_id) do
      result
    else
      {:error, reason} ->
        email = invite_email(invite)

        Sentry.capture_message("Bulk invitation failed",
          level: :error,
          extra: %{email: email, reason: inspect(reason)}
        )

        Logger.error("[bulk-invite-worker] Failed to process invitation",
          email: email,
          reason: inspect(reason)
        )

        %{email: email || "unknown", success: false, error: inspect(reason)}
    end
  end

  defp resolve_invite_data(waitlist_id) when is_binary(waitlist_id) do
    query =
      from up in "user_profiles",
        join: w in "waitlist",
        on: w.id == up.waitlist_id,
        where: up.waitlist_id == type(^waitlist_id, Ecto.UUID),
        select: %{
          "firstName" => up.first_name,
          "lastName" => up.last_name,
          "email" => w.email,
          "dateOfBirth" => up.date_of_birth,
          "phoneNumber" => up.phone_number
        }

    case Repo.one(query) do
      nil -> {:error, {:waitlist_not_found, waitlist_id}}
      invite_data -> {:ok, invite_data}
    end
  end

  defp resolve_invite_data(invite) when is_map(invite) do
    required = ~w(firstName lastName email phoneNumber dateOfBirth)
    missing = Enum.filter(required, &(is_nil(invite[&1]) or invite[&1] == ""))

    if missing == [], do: {:ok, invite}, else: {:error, {:invalid_invite, missing}}
  end

  defp resolve_invite_data(_invite), do: {:error, :invalid_invite_shape}

  defp create_invitation_pipeline(original_invite, invite_data, created_by_id) do
    Repo.transaction(fn ->
      with {:ok, customer} <- create_stripe_customer(invite_data, created_by_id),
           {:ok, auth_user} <- create_supabase_user(invite_data),
           {:ok, invitation_id} <-
             create_invitation_record(
               original_invite,
               invite_data,
               auth_user["id"],
               customer["id"],
               created_by_id
             ),
           :ok <- enqueue_invitation_email(invite_data, invitation_id),
           :ok <- maybe_update_waitlist(original_invite) do
        Logger.info("[bulk-invite-worker] Processed invitation",
          email: invite_data["email"],
          invitation_id: invitation_id,
          stripe_customer_id: customer["id"]
        )

        %{email: invite_data["email"], success: true, invitationId: invitation_id}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_stripe_customer(invite_data, created_by_id) do
    body = %{
      "name" => Enum.join([invite_data["firstName"], invite_data["lastName"]], " "),
      "email" => invite_data["email"],
      "metadata[invited_by]" => created_by_id
    }

    case StripeClient.request(method: :post, url: "/v1/customers", body: body) do
      {:ok, %{"id" => _id} = customer} -> {:ok, customer}
      {:ok, body} -> {:error, {:stripe_customer_missing_id, body}}
      {:error, reason} -> {:error, {:stripe_customer, reason}}
    end
  end

  defp create_supabase_user(invite_data) do
    with {:ok, url} <- supabase_auth_admin_url(),
         {:ok, service_key} <- supabase_service_role_key() do
      payload = %{
        email: invite_data["email"],
        email_confirm: true,
        user_metadata: %{
          first_name: invite_data["firstName"],
          last_name: invite_data["lastName"]
        }
      }

      case Req.post(url,
             json: payload,
             headers: [
               {"authorization", "Bearer #{service_key}"},
               {"apikey", service_key},
               {"content-type", "application/json"}
             ]
           ) do
        {:ok, %Req.Response{status: status, body: %{"id" => _id} = user}}
        when status in 200..299 ->
          {:ok, user}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:supabase_auth, status, body}}

        {:error, exception} ->
          {:error, {:supabase_auth_http, exception}}
      end
    end
  end

  defp create_invitation_record(original_invite, invite_data, user_id, customer_id, created_by_id) do
    waitlist_id =
      if is_binary(original_invite), do: original_invite, else: Map.get(invite_data, "waitlistId")

    expires_at = DateTime.add(DateTime.utc_now(), 7, :day)

    sql = """
    with expired_existing as (
      update invitations
      set status = 'expired', updated_at = now()
      where email = $2::text and status = 'pending'
    ), profile as (
      insert into user_profiles (
        supabase_user_id,
        first_name,
        last_name,
        date_of_birth,
        phone_number,
        customer_id,
        is_active,
        waitlist_id
      ) values (
        $1::uuid,
        $3::text,
        $4::text,
        $5::date,
        $6::text,
        $7::text,
        false,
        $8::uuid
      )
      on conflict (supabase_user_id)
      do update set
        first_name = excluded.first_name,
        last_name = excluded.last_name,
        date_of_birth = excluded.date_of_birth,
        phone_number = excluded.phone_number,
        customer_id = excluded.customer_id,
        waitlist_id = coalesce(excluded.waitlist_id, user_profiles.waitlist_id),
        updated_at = now()
    ), invitation as (
      insert into invitations (
        email,
        user_id,
        waitlist_id,
        status,
        expires_at,
        created_by,
        invitation_type,
        metadata
      ) values (
        $2::text,
        $1::uuid,
        $8::uuid,
        'pending',
        $9::timestamptz,
        $10::uuid,
        $11::text,
        $12::jsonb
      )
      returning id
    )
    select id from invitation
    """

    params = [
      user_id,
      invite_data["email"],
      invite_data["firstName"],
      invite_data["lastName"],
      date_string(invite_data["dateOfBirth"]),
      invite_data["phoneNumber"],
      customer_id,
      waitlist_id,
      expires_at,
      created_by_id,
      Map.get(invite_data, "invitationType", "admin"),
      maybe_json(Map.get(invite_data, "metadata"))
    ]

    case Ecto.Adapters.SQL.query(Repo, sql, params) do
      {:ok, %{rows: [[invitation_id]]}} -> {:ok, invitation_id}
      {:error, reason} -> {:error, {:create_invitation, reason}}
    end
  end

  defp maybe_json(nil), do: nil
  defp maybe_json(value), do: Jason.encode!(value)

  defp date_string(%Date{} = date), do: Date.to_iso8601(date)
  defp date_string(%DateTime{} = date_time), do: DateTime.to_date(date_time) |> Date.to_iso8601()

  defp date_string(value) when is_binary(value) do
    value
    |> String.split("T")
    |> List.first()
  end

  defp date_string(value), do: to_string(value)

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
    from(w in "waitlist", where: w.id == type(^waitlist_id, Ecto.UUID))
    |> Repo.update_all(set: [status: "invited", last_status_change: DateTime.utc_now()])

    :ok
  end

  defp maybe_update_waitlist(_invite), do: :ok

  defp store_processing_results(results, created_by_id) do
    success_count = Enum.count(results, & &1.success)
    failure_count = length(results) - success_count

    sql = """
    insert into invitation_processing_logs (user_id, total_count, success_count, failure_count, results)
    values ($1::uuid, $2::integer, $3::integer, $4::integer, $5::jsonb)
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [
           created_by_id,
           length(results),
           success_count,
           failure_count,
           Jason.encode!(results)
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:processing_log, reason}}
    end
  end

  defp create_notification(results, created_by_id) do
    success_count = Enum.count(results, & &1.success)
    failure_count = length(results) - success_count

    body =
      if failure_count == 0 do
        "Successfully processed #{success_count} invitations out of #{length(results)}"
      else
        "Successfully processed #{success_count} invitations out of #{length(results)}, failed to process #{failure_count} invitations"
      end

    case Ecto.Adapters.SQL.query(
           Repo,
           "insert into notifications (user_id, body) values ($1::uuid, $2::text)",
           [created_by_id, body]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:notification, reason}}
    end
  end

  defp invitation_link(invite_data, invitation_id) do
    app_url = Application.get_env(:dhc, :app_url, @default_app_url)

    app_url
    |> URI.merge("/members/signup/#{invitation_id}")
    |> Map.put(
      :query,
      URI.encode_query(%{
        "dateOfBirth" => date_string(invite_data["dateOfBirth"]),
        "email" => invite_data["email"]
      })
    )
    |> URI.to_string()
  end

  defp supabase_auth_admin_url do
    case Application.get_env(:dhc, :supabase_url) do
      nil -> {:error, :supabase_url_not_configured}
      "" -> {:error, :supabase_url_not_configured}
      url -> {:ok, URI.merge(url, "/auth/v1/admin/users") |> URI.to_string()}
    end
  end

  defp supabase_service_role_key do
    case Application.get_env(:dhc, :supabase_service_role_key) do
      nil -> {:error, :supabase_service_role_key_not_configured}
      "" -> {:error, :supabase_service_role_key_not_configured}
      key -> {:ok, key}
    end
  end

  defp invite_email(%{"email" => email}), do: email
  defp invite_email(_invite), do: nil
end
