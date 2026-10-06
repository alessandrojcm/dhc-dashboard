defmodule DhcWeb.WorkshopsController do
  use DhcWeb, :controller

  alias Dhc.Workshops

  action_fallback DhcWeb.WorkshopsHTTP

  @moduledoc """
  Workshop management reads.

  `calendar/2` and `attendees/2` are protected by the `:workshop_coordinator_api`
  pipeline (`workshop_coordinator`, `president`, `admin`). `list/2` is
  authenticated-only.

  See `Dhc.Workshops` for the historical `beginners_coordinator`
  registration-visibility drift that the coordinator endpoints deliberately
  do not reproduce.
  """

  @doc """
  GET /workshops/calendar

  Returns non-cancelled Workshops for the coordinator management calendar,
  with interest, active Registration counts, and capacity projections.

  The DTO carries no current-user registration or interest state; those were
  PostgREST join artifacts (PRD #142). Month/date-window pagination is out of
  scope, so the full non-cancelled set is returned.
  """
  def calendar(conn, _params) do
    workshops = Workshops.list_workshop_summaries(exclude_statuses: ~w(cancelled))

    conn
    |> put_view(json: DhcWeb.WorkshopsJSON)
    |> render(:calendar, workshops: workshops)
  end

  @doc """
  GET /workshops

  Returns the member-safe Workshop collection. Status is constrained to
  `planned` and `published`, and each Workshop includes the current user's
  interest and registration state.
  """
  def list(conn, params) do
    workshops = Workshops.list_member_workshops(conn.assigns.current_session.principal.id, params)

    conn
    |> put_view(json: DhcWeb.WorkshopsJSON)
    |> render(:list, workshops: workshops)
  end

  @doc """
  POST /workshops

  Creates a planned Workshop. Coordinator/admin-only via router pipeline.
  """
  def create(conn, params) do
    params
    |> management_attrs()
    |> Workshops.create_workshop(conn.assigns.current_session.principal.id)
    |> case do
      {:ok, workshop} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:management, workshop: Workshops.workshop_summary(workshop.id))

      error ->
        error
    end
  end

  @doc """
  GET /workshops/{id}

  Returns a management Workshop summary for coordinators/admins.
  """
  def show(conn, %{"id" => id}) do
    case Workshops.workshop_summary(id) do
      nil -> {:error, :not_found}
      workshop -> render_management(conn, workshop)
    end
  end

  @doc """
  PATCH /workshops/{id}

  Updates Workshop management fields. Status/lifecycle fields are deliberately
  ignored; publish/cancel have dedicated command endpoints.
  """
  def update(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.delete("id")
      |> management_attrs()

    with {:ok, workshop} <- Workshops.update_workshop(id, attrs) do
      render_management(conn, Workshops.workshop_summary(workshop.id))
    end
  end

  @doc """
  DELETE /workshops/{id}

  ALE-181: registrations-existence gates archive-vs-hard-delete.

    * Workshop with registrations → `200` + archived Workshop body (soft-delete).
    * Workshop with no registrations → `204` (hard-delete).
    * Already-archived Workshop → `409`.
    * Unknown Workshop → `404`.
  """
  def delete(conn, %{"id" => id}) do
    case Workshops.delete_workshop(id) do
      {:ok, :deleted} ->
        send_resp(conn, :no_content, "")

      {:ok, :archived, workshop} ->
        render_management(conn, workshop)

      error ->
        error
    end
  end

  @doc """
  POST /workshops/{id}/publish
  """
  def publish(conn, %{"id" => id}) do
    with {:ok, workshop} <- Workshops.publish_workshop(id) do
      render_management(conn, Workshops.workshop_summary(workshop.id))
    end
  end

  @doc """
  POST /workshops/{id}/cancel
  """
  def cancel(conn, %{"id" => id}) do
    with {:ok, workshop} <-
           Workshops.cancel_workshop(id, conn.assigns.current_session.principal.id) do
      render_management(conn, Workshops.workshop_summary(workshop.id))
    end
  end

  @doc """
  POST /workshops/{id}/interest

  Toggles the authenticated member's interest in a planned Workshop.
  """
  def toggle_interest(conn, %{"id" => id}) do
    with {:ok, result} <-
           Workshops.toggle_interest(id, conn.assigns.current_session.principal.id) do
      conn
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:interest, result: result)
    end
  end

  @doc """
  POST /workshops/{id}/registration/payment-intent

  Creates a Stripe PaymentIntent for the authenticated member's Workshop
  registration after duplicate and capacity checks.
  """
  def create_registration_payment_intent(conn, %{"id" => id} = params) do
    with {:ok, result} <-
           Workshops.create_member_payment_intent(
             id,
             conn.assigns.current_session.principal.id,
             params
           ) do
      conn
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:registration_payment_intent, result: result)
    end
  end

  @doc """
  POST /workshops/{id}/registration/complete

  Completes the authenticated member's registration after Stripe confirms the
  PaymentIntent.
  """
  def complete_registration(conn, %{"id" => id, "paymentIntentId" => payment_intent_id}) do
    with {:ok, registration} <-
           Workshops.complete_member_registration(
             id,
             conn.assigns.current_session.principal.id,
             payment_intent_id
           ) do
      conn
      |> put_status(:created)
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:registration, registration: registration)
    end
  end

  def complete_registration(_conn, _params), do: {:error, :payment_intent_required}

  def external_registration_gate(conn, %{"id" => id}) do
    gate =
      case Ecto.UUID.cast(id) do
        {:ok, workshop_id} -> Workshops.external_registration_gate(workshop_id)
        :error -> %{can_register: false, reason: "NOT_FOUND"}
      end

    conn
    |> put_view(json: DhcWeb.WorkshopsJSON)
    |> render(:external_registration_gate, gate: gate)
  end

  def create_external_checkout_session(conn, %{
        "id" => id,
        "paymentAttemptId" => payment_attempt_id,
        "returnUrl" => return_url
      })
      when is_binary(payment_attempt_id) and is_binary(return_url) do
    with {:ok, workshop_id} <- Ecto.UUID.cast(id),
         {:ok, attempt_id} <- Ecto.UUID.cast(payment_attempt_id),
         {:ok, result} <-
           Workshops.create_external_checkout_session(workshop_id, attempt_id, return_url) do
      conn
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:external_checkout_session, result: result)
    else
      error -> external_registration_error(error)
    end
  end

  def create_external_checkout_session(_conn, _params),
    do: {:error, :checkout_details_required}

  def complete_external_registration(conn, %{
        "id" => id,
        "checkoutSessionId" => checkout_session_id
      })
      when is_binary(checkout_session_id) and byte_size(checkout_session_id) > 0 do
    with {:ok, workshop_id} <- Ecto.UUID.cast(id),
         {:ok, registration} <-
           Workshops.complete_external_registration(workshop_id, checkout_session_id) do
      conn
      |> put_status(:created)
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:registration, registration: registration)
    else
      error -> external_registration_error(error)
    end
  end

  def complete_external_registration(_conn, _params),
    do: {:error, :checkout_session_required}

  @doc """
  DELETE /workshops/{id}/registration

  Cancels the authenticated member's active registration.
  """
  def cancel_registration(conn, %{"id" => id}) do
    with {:ok, result} <-
           Workshops.cancel_member_registration(id, conn.assigns.current_session.principal.id) do
      conn
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:registration_cancelled, result: result)
    end
  end

  @doc """
  GET /workshops/{id}/attendees

  Returns the combined coordinator attendee/refund management payload for a
  single Workshop: Workshop summary, active attendees (pending/confirmed),
  and refunds. Returns 404 when no Workshop exists for the given id.
  """
  def attendees(conn, %{"id" => id}) do
    case Workshops.workshop_attendees_and_refunds(id) do
      %{workshop: nil} ->
        {:error, :not_found}

      %{workshop: workshop, attendees: attendees, refunds: refunds} ->
        conn
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:attendees, workshop: workshop, attendees: attendees, refunds: refunds)
    end
  end

  @doc """
  GET /workshops/{id}/refunds

  Returns coordinator-visible refund records for one Workshop.
  """
  def refunds(conn, %{"id" => id}) do
    case Workshops.workshop_summary(id) do
      nil ->
        {:error, :not_found}

      _workshop ->
        conn
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:refunds, refunds: Workshops.list_workshop_refunds(id))
    end
  end

  @doc """
  POST /workshops/{id}/registrations/{registration_id}/refund

  Explicitly refunds an eligible Workshop registration. Coordinator identity is
  derived from the authenticated JWT and recorded on the refund attempt.
  """
  def refund_registration(
        conn,
        %{"id" => workshop_id, "registration_id" => registration_id, "reason" => reason}
      )
      when is_binary(reason) and byte_size(reason) > 0 and byte_size(reason) <= 500 do
    reason = String.trim(reason)

    if reason == "" do
      {:error, :refund_reason_required}
    else
      process_registration_refund(conn, workshop_id, registration_id, reason)
    end
  end

  def refund_registration(_conn, _params), do: {:error, :refund_reason_required}

  defp process_registration_refund(conn, workshop_id, registration_id, reason) do
    case Workshops.process_refund(
           workshop_id,
           registration_id,
           reason,
           conn.assigns.current_session.principal.id
         ) do
      {:ok, refund} ->
        rendered_refund =
          workshop_id
          |> Workshops.list_workshop_refunds()
          |> Enum.find(&(&1.id == refund.id))

        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:refund, refund: rendered_refund)

      # A refund request's own `:already_requested` is a 422; the 409
      # reason of that name belongs to Workshop cancellation.
      {:error, :already_requested} ->
        {:error, :refund_already_requested}

      error ->
        error
    end
  end

  @doc """
  PATCH /workshops/{id}/attendance

  Atomically records attendance for active Workshop attendees after the Workshop
  start time. The coordinator identity is derived from the authenticated JWT.
  """
  def update_attendance(conn, %{"id" => id, "updates" => updates}) when is_list(updates) do
    with {:ok, updates} <- attendance_updates(updates),
         {:ok, registrations} <-
           Workshops.update_workshop_attendance(
             id,
             conn.assigns.current_session.principal.id,
             updates
           ) do
      conn
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:attendance, registrations: registrations)
    end
  end

  def update_attendance(_conn, _params), do: {:error, :attendance_updates_required}

  defp render_management(conn, workshop) do
    conn
    |> put_view(json: DhcWeb.WorkshopsJSON)
    |> render(:management, workshop: workshop)
  end

  defp management_attrs(params) do
    %{}
    |> put_if_present(params, "title", :title)
    |> put_if_present(params, "description", :description)
    |> put_if_present(params, "location", :location)
    |> put_datetime_if_present(params, "startDate", :start_date)
    |> put_datetime_if_present(params, "endDate", :end_date)
    |> put_if_present(params, "maxCapacity", :max_capacity)
    |> put_if_present(params, "priceMember", :price_member)
    |> put_if_present(params, "priceNonMember", :price_non_member)
    |> put_if_present(params, "isPublic", :is_public)
    |> put_if_present(params, "refundDays", :refund_days)
    |> put_if_present(params, "announceDiscord", :announce_discord)
    |> put_if_present(params, "announceEmail", :announce_email)
  end

  defp attendance_updates(updates) do
    updates
    |> Enum.reduce_while({:ok, []}, fn update, {:ok, parsed} ->
      with registration_id when is_binary(registration_id) <- Map.get(update, "registrationId"),
           {:ok, registration_id} <- Ecto.UUID.cast(registration_id),
           attendance_status when attendance_status in ["attended", "noShow", "excused"] <-
             Map.get(update, "attendanceStatus"),
           notes when is_nil(notes) or (is_binary(notes) and byte_size(notes) <= 500) <-
             Map.get(update, "notes") do
        {:cont,
         {:ok,
          [
            %{
              registration_id: registration_id,
              attendance_status: attendance_status_to_persistence(attendance_status),
              notes: notes
            }
            | parsed
          ]}}
      else
        _ -> {:halt, {:error, :invalid_updates}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp attendance_status_to_persistence("noShow"), do: "no_show"
  defp attendance_status_to_persistence(status), do: status

  defp put_if_present(attrs, params, source, target) do
    case Map.fetch(params, source) do
      {:ok, value} -> Map.put(attrs, target, value)
      :error -> attrs
    end
  end

  defp put_datetime_if_present(attrs, params, source, target) do
    case Map.fetch(params, source) do
      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> Map.put(attrs, target, DateTime.truncate(datetime, :second))
          {:error, _reason} -> Map.put(attrs, target, value)
        end

      {:ok, value} ->
        Map.put(attrs, target, value)

      :error ->
        attrs
    end
  end

  # External Checkout wording differs from the member PaymentIntent flow.
  defp external_registration_error(:error), do: {:error, :not_found}

  defp external_registration_error({:error, :already_registered}),
    do: {:error, :email_already_registered}

  defp external_registration_error({:error, :payment_metadata_mismatch}),
    do: {:error, :checkout_metadata_mismatch}

  defp external_registration_error(error), do: error
end
