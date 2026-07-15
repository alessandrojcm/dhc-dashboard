defmodule DhcWeb.WorkshopsController do
  use DhcWeb, :controller

  alias Dhc.Workshops

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
  with interest and pending/confirmed registration counts.

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
    workshops = Workshops.list_member_workshops(conn.assigns.current_user.sub, params)

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
    |> Workshops.create_workshop(conn.assigns.current_user.sub)
    |> case do
      {:ok, workshop} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:management, workshop: Workshops.workshop_summary(workshop.id))

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  @doc """
  GET /workshops/{id}

  Returns a management Workshop summary for coordinators/admins.
  """
  def show(conn, %{"id" => id}) do
    case Workshops.workshop_summary(id) do
      nil -> not_found(conn)
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

    case Workshops.update_workshop(id, attrs) do
      {:ok, workshop} ->
        render_management(conn, Workshops.workshop_summary(workshop.id))

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)

      {:error, reason} ->
        lifecycle_error(conn, reason)
    end
  end

  @doc """
  DELETE /workshops/{id}

  Deletes planned Workshops only.
  """
  def delete(conn, %{"id" => id}) do
    case Workshops.delete_workshop(id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, reason} -> lifecycle_error(conn, reason)
    end
  end

  @doc """
  POST /workshops/{id}/publish
  """
  def publish(conn, %{"id" => id}) do
    case Workshops.publish_workshop(id) do
      {:ok, workshop} -> render_management(conn, Workshops.workshop_summary(workshop.id))
      {:error, reason} -> lifecycle_error(conn, reason)
    end
  end

  @doc """
  POST /workshops/{id}/cancel
  """
  def cancel(conn, %{"id" => id}) do
    case Workshops.cancel_workshop(id, conn.assigns.current_user.sub) do
      {:ok, workshop} -> render_management(conn, Workshops.workshop_summary(workshop.id))
      {:error, reason} -> lifecycle_error(conn, reason)
    end
  end

  @doc """
  POST /workshops/{id}/interest

  Toggles the authenticated member's interest in a planned Workshop.
  """
  def toggle_interest(conn, %{"id" => id}) do
    case Workshops.toggle_interest(id, conn.assigns.current_user.sub) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:interest, result: result)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :not_planned} ->
        unprocessable(conn, "Can only express interest in planned workshops")
    end
  end

  @doc """
  POST /workshops/{id}/registration/payment-intent

  Creates a Stripe PaymentIntent for the authenticated member's Workshop
  registration after duplicate and capacity checks.
  """
  def create_registration_payment_intent(conn, %{"id" => id} = params) do
    case Workshops.create_member_payment_intent(id, conn.assigns.current_user.sub, params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:registration_payment_intent, result: result)

      {:error, reason} ->
        member_registration_error(conn, reason)
    end
  end

  @doc """
  POST /workshops/{id}/registration/complete

  Completes the authenticated member's registration after Stripe confirms the
  PaymentIntent.
  """
  def complete_registration(conn, %{"id" => id, "paymentIntentId" => payment_intent_id}) do
    case Workshops.complete_member_registration(
           id,
           conn.assigns.current_user.sub,
           payment_intent_id
         ) do
      {:ok, registration} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:registration, registration: registration)

      {:error, reason} ->
        member_registration_error(conn, reason)
    end
  end

  def complete_registration(conn, _params) do
    unprocessable(conn, "Payment intent ID required")
  end

  @doc """
  DELETE /workshops/{id}/registration

  Cancels the authenticated member's active registration.
  """
  def cancel_registration(conn, %{"id" => id}) do
    case Workshops.cancel_member_registration(id, conn.assigns.current_user.sub) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:registration_cancelled, result: result)

      {:error, reason} ->
        member_registration_error(conn, reason)
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
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Workshop not found"}})

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
        not_found(conn)

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
      unprocessable(conn, "Refund reason is required")
    else
      process_registration_refund(conn, workshop_id, registration_id, reason)
    end
  end

  def refund_registration(conn, _params), do: unprocessable(conn, "Refund reason is required")

  defp process_registration_refund(conn, workshop_id, registration_id, reason) do
    case Workshops.process_refund(
           workshop_id,
           registration_id,
           reason,
           conn.assigns.current_user.sub
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

      {:error, reason} ->
        refund_error(conn, reason)
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
           Workshops.update_workshop_attendance(id, conn.assigns.current_user.sub, updates) do
      conn
      |> put_view(json: DhcWeb.WorkshopsJSON)
      |> render(:attendance, registrations: registrations)
    else
      {:error, reason} -> attendance_error(conn, reason)
    end
  end

  def update_attendance(conn, _params), do: unprocessable(conn, "Attendance updates are required")

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

  defp lifecycle_error(conn, :not_found), do: not_found(conn)

  defp lifecycle_error(conn, :not_editable) do
    unprocessable(conn, "Only planned workshops can be edited")
  end

  defp lifecycle_error(conn, :pricing_locked) do
    unprocessable(conn, "Cannot change pricing when there are active registrations")
  end

  defp lifecycle_error(conn, :not_deletable) do
    unprocessable(conn, "Only planned workshops can be deleted")
  end

  defp lifecycle_error(conn, :not_publishable) do
    unprocessable(conn, "Only planned workshops can be published")
  end

  defp lifecycle_error(conn, :not_cancellable) do
    unprocessable(conn, "Only published workshops can be cancelled")
  end

  defp member_registration_error(conn, :not_found), do: not_found(conn)

  defp member_registration_error(conn, :not_published),
    do: unprocessable(conn, "Workshop not available for registration")

  defp member_registration_error(conn, :already_registered),
    do: conflict(conn, "Already registered for this workshop")

  defp member_registration_error(conn, :full), do: conflict(conn, "Workshop is full")

  defp member_registration_error(conn, :invalid_amount),
    do: unprocessable(conn, "Amount must be positive")

  defp member_registration_error(conn, :payment_not_completed),
    do: unprocessable(conn, "Payment not completed")

  defp member_registration_error(conn, :payment_metadata_mismatch),
    do: unprocessable(conn, "Payment intent does not match workshop registration")

  defp member_registration_error(conn, :payment_failed),
    do:
      conn
      |> put_status(:bad_gateway)
      |> json(%{errors: %{detail: "Payment provider request failed"}})

  defp member_registration_error(conn, :refund_failed), do: refund_provider_error(conn)

  defp refund_error(conn, :registration_not_found), do: not_found(conn)

  defp refund_error(conn, :already_refunded),
    do: unprocessable(conn, "Registration already refunded")

  defp refund_error(conn, :workshop_finished),
    do: unprocessable(conn, "Cannot refund finished workshop")

  defp refund_error(conn, :not_paid),
    do: unprocessable(conn, "Registration has no payment to refund")

  defp refund_error(conn, :deadline_passed), do: unprocessable(conn, "Refund deadline has passed")

  defp refund_error(conn, :already_requested),
    do: unprocessable(conn, "Refund already requested for this registration")

  defp refund_error(conn, :refund_failed), do: refund_provider_error(conn)

  defp refund_provider_error(conn) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{errors: %{detail: "Refund provider request failed"}})
  end

  defp attendance_error(conn, :not_found), do: not_found(conn)

  defp attendance_error(conn, :not_started) do
    unprocessable(conn, "Cannot update attendance before the Workshop has started")
  end

  defp attendance_error(conn, :invalid_attendee) do
    unprocessable(conn, "Attendance updates must target active Workshop attendees")
  end

  defp attendance_error(conn, :invalid_updates),
    do: unprocessable(conn, "Invalid attendance updates")

  defp conflict(conn, message) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: message}})
  end

  defp validation_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "Invalid Workshop", fields: changeset_errors(changeset)}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Workshop not found"}})
  end

  defp unprocessable(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail}})
  end
end
