defmodule DhcWeb.MembershipController do
  use DhcWeb, :controller

  alias Dhc.Membership

  @members_admin_roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

  @doc """
  POST /members/:memberId/membership/pause
  """
  def pause(conn, %{"memberId" => member_id} = params) do
    attrs = Map.delete(params, "memberId")

    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, member} <- Membership.pause(member_id, attrs) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:show, member: member)
    else
      {:error, :forbidden} -> forbidden(conn, "Insufficient role")
      {:error, :not_found} -> not_found(conn, "Member not found")
      {:error, :subscription_not_found} -> conflict(conn, "Membership subscription not found")
      {:error, :invalid_payload} -> validation_error(conn, "Invalid membership pause payload")
      {:error, :stripe_error} -> bad_gateway(conn, "Stripe membership update failed")
      {:error, %Ecto.Changeset{} = changeset} -> validation_error(conn, changeset)
    end
  end

  @doc """
  POST /members/:memberId/membership/resume
  """
  def resume(conn, %{"memberId" => member_id}) do
    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, member} <- Membership.resume(member_id) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:show, member: member)
    else
      {:error, :forbidden} -> forbidden(conn, "Insufficient role")
      {:error, :not_found} -> not_found(conn, "Member not found")
      {:error, :subscription_not_found} -> conflict(conn, "Membership subscription not found")
      {:error, :stripe_error} -> bad_gateway(conn, "Stripe membership update failed")
    end
  end

  @doc "POST /members/:memberId/billing-portal"
  def billing_portal(conn, %{"memberId" => member_id, "returnUrl" => return_url}) do
    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, url} <- Membership.create_billing_portal_session(member_id, return_url) do
      json(conn, %{data: %{url: url}})
    else
      {:error, :forbidden} -> forbidden(conn, "Insufficient role")
      {:error, :not_found} -> not_found(conn, "Member not found")
      {:error, :invalid_payload} -> validation_error(conn, "Invalid billing portal return URL")
      {:error, :stripe_error} -> bad_gateway(conn, "Stripe billing portal request failed")
    end
  end

  def billing_portal(conn, _params),
    do: validation_error(conn, "Invalid billing portal payload")

  @doc """
  POST /members/:memberId/membership/reactivate

  Restricted by the `:membership_minting_api` pipeline to officers with
  billing authority (admin, president, treasurer, committee_coordinator) —
  there is no self-service fallback because the command mints new Stripe
  charges.
  """
  def reactivate(conn, %{"memberId" => member_id} = params) do
    attrs =
      params
      |> Map.delete("memberId")
      |> Map.put("operatorPrincipalId", conn.assigns.current_session.principal.id)

    case Membership.reactivate(member_id, attrs) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, :invalid_payload} ->
        validation_error(conn, "Invalid membership reactivation payload")

      {:error, :not_found} ->
        not_found(conn, "Member not found")

      {:error, :membership_paused} ->
        conflict(conn, "Member's membership subscription is paused")

      {:error, :membership_active} ->
        conflict(conn, "Member already has an active membership subscription")

      {:error, :no_saved_payment_method} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          errors: %{
            detail:
              "Member has no usable saved SEPA payment method; use the billing portal as fallback",
            code: "no_saved_payment_method"
          }
        })

      {:error, :stripe_error} ->
        bad_gateway(conn, "Stripe membership reactivation failed")
    end
  end

  defp authorize_self_or_admin(conn, member_id) do
    current_session = conn.assigns.current_session

    if current_session.principal.id == member_id or
         Enum.any?(current_session.roles, &(&1 in @members_admin_roles)) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp forbidden(conn, detail) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: detail}})
  end

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: detail}})
  end

  defp conflict(conn, detail) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: detail}})
  end

  defp bad_gateway(conn, detail) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{errors: %{detail: detail}})
  end

  defp validation_error(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: %{detail: "Invalid membership pause payload", fields: changeset_errors(changeset)}
    })
  end

  defp validation_error(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
  end
end
