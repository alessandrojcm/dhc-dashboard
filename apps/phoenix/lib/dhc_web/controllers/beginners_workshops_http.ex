defmodule DhcWeb.BeginnersWorkshopsHTTP do
  @moduledoc """
  Input mapping and the problem fallback for the Beginners' Workshops HTTP
  slices (ALE-378). Controllers declare
  `action_fallback DhcWeb.BeginnersWorkshopsHTTP` and pass the boundary's
  result through `respond/4`.

  A refused `schedule_workshop` names the workshop it failed on; `respond/4`
  turns that into dotted `fields` keys (`workshops.<index>.<field>`) so the
  dashboard can put the message under the right row.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias DhcWeb.Problem

  # Public camelCase request field → internal attribute.
  @fields %{
    "venue" => "venue",
    "date" => "date",
    "startTime" => "start_time",
    "capacity" => "capacity",
    "feeCents" => "fee_cents",
    "paymentCutoffDate" => "payment_cutoff_date",
    "paymentCutoffTime" => "payment_cutoff_time",
    "contactFromDate" => "contact_from",
    "paymentWindowDays" => "payment_window_days",
    "coachPrincipalId" => "coach_principal_id",
    "assistantPrincipalIds" => "assistant_principal_ids"
  }

  @internal_to_public Map.new(@fields, fn {public, internal} -> {internal, public} end)
                      |> Map.put("payment_cutoff", "paymentCutoffDate")

  # The field a named refusal is about.
  @reason_fields %{
    start_in_past: "date",
    invalid_payment_cutoff: "paymentCutoffDate",
    invalid_contact_from: "contactFromDate",
    contact_from_locked: "contactFromDate",
    fee_locked: "feeCents",
    capacity_below_taken: "capacity",
    not_a_coach: "coachPrincipalId",
    not_a_member: "assistantPrincipalIds",
    email_on_waitlist: "email",
    email_is_principal: "email",
    email_has_pending_invitation: "email"
  }

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Beginners' Workshop not found"},
      after_finalisation: {409, "This workshop's attendance is final; it can no longer change"},
      already_cancelled: {409, "This workshop is cancelled"},
      contact_from_locked:
        {409, "Batch 1 has gone out, so the contact-from date can no longer change"},
      fee_locked: {409, "People have been contacted at this fee, so it can no longer change"},
      capacity_below_taken:
        {409, "Capacity can't go below the seats already paid or held by people paying now"},
      invalid_workshop: {422, "Check the workshop details"},
      start_in_past: {422, "The workshop must start in the future"},
      invalid_payment_cutoff: {422, "The Payment Cutoff must be before the workshop starts"},
      invalid_contact_from: {422, "The contact-from date must be on or before the cutoff date"},
      no_workshops: {422, "Add at least one workshop"},
      invalid_staff: {422, "Check the Staff"},
      not_a_coach: {422, "The coach must be a Member with the coach role"},
      not_a_member: {422, "Assistants must be active Members"},
      staff_conflict: {409, "The Staff changed at the same time; try again"},
      too_many_workshops: {422, "Schedule at most 20 workshops at once"},
      # Fast-track (ALE-384).
      person_not_found: {404, "Waitlist person not found"},
      open_intake: {409, "This person already has an open Intake"},
      not_eligible:
        {409, "Only someone waiting, or removed in the last 3 months, can be fast-tracked"},
      after_cutoff: {409, "Payment is closed for this workshop, so nobody can be fast-tracked"},
      email_on_waitlist: {409, "This email is already on the Waitlist; search for them instead"},
      email_is_principal: {409, "This email belongs to a Member or former Member"},
      email_has_pending_invitation: {409, "This email already has a pending Invitation"},
      invalid_payload: {422, "Check the person's details"},
      # Refund follow-ups (ALE-382).
      refund_not_found: {404, "Refund not found"},
      refund_not_failed: {409, "Only a failed refund can be retried or recorded as manual"},
      refund_followed_up: {409, "This failed refund was already retried or recorded as manual"},
      already_requested: {409, "This payment already has a refund in progress or completed"},
      # Door check-in (ALE-390).
      check_in_not_open: {409, "Check-in opens an hour before the workshop starts"},
      check_in_closed: {409, "Check-in has closed for this workshop"},
      not_paid: {409, "Only people who have paid can be checked in"},
      # Attendance Finalisation (ALE-391).
      payment_in_progress:
        {409, "Someone is still paying; finish the workshop once their payment ends"}
    },
    fields: @internal_to_public

  def actor(conn), do: {:staff, conn.assigns.current_session.principal.id}

  @doc "Keeps only the public request vocabulary, renamed to internal keys."
  def attrs(params) when is_map(params) do
    for {public, internal} <- @fields,
        Map.has_key?(params, public),
        into: %{},
        do: {internal, Map.fetch!(params, public)}
  end

  def attrs(_params), do: :invalid

  @doc """
  A `set_staff` request: the whole Staff list. A missing `coachPrincipalId`
  means no coach and missing `assistantPrincipalIds` no assistants.
  """
  def staff_attrs(params) when is_map(params) do
    %{
      "coach_principal_id" => Map.get(params, "coachPrincipalId"),
      "assistant_principal_ids" => Map.get(params, "assistantPrincipalIds", [])
    }
  end

  @doc "The `workshops` list of a schedule request, each entry mapped by `attrs/1`."
  def schedule_attrs(%{"workshops" => workshops}) when is_list(workshops),
    do: {:ok, Enum.map(workshops, &attrs/1)}

  def schedule_attrs(_params), do: {:error, ["workshops must be a list"]}

  @doc "Renders `{:ok, result}`; translates and returns any error to the fallback."
  def respond(result, conn, template, status \\ :ok)

  def respond({:ok, result}, conn, template, status),
    do: conn |> put_status(status) |> render(template, result: result)

  def respond({:error, {:workshop, index, reason}}, _conn, _template, _status),
    do: workshop_error(index, reason)

  def respond({:error, reason}, _conn, _template, _status)
      when is_map_key(@reason_fields, reason),
      do: {:error, reason, %{Map.fetch!(@reason_fields, reason) => [detail(reason)]}}

  def respond(error, _conn, _template, _status), do: error

  defp workshop_error(index, %Ecto.Changeset{} = changeset) do
    fields =
      changeset
      |> Problem.changeset_fields(@internal_to_public)
      |> Map.new(fn {field, messages} -> {"workshops.#{index}.#{field}", messages} end)

    {:error, :invalid_workshop, fields}
  end

  defp workshop_error(index, reason) when is_map_key(@reason_fields, reason),
    do:
      {:error, reason,
       %{"workshops.#{index}.#{Map.fetch!(@reason_fields, reason)}" => [detail(reason)]}}

  defp workshop_error(_index, reason), do: {:error, reason}

  defp detail(reason) do
    {_status, detail} = Map.fetch!(@problem_config.reasons, reason)
    detail
  end
end
