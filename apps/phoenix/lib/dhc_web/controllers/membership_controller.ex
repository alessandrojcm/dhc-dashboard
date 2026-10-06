defmodule DhcWeb.MembershipController do
  use DhcWeb, :controller

  alias Dhc.Auth.Capabilities
  alias Dhc.Membership

  action_fallback DhcWeb.MembersHTTP

  @doc """
  POST /members/:memberId/membership/pause
  """
  def pause(conn, %{"memberId" => member_id} = params) do
    attrs = Map.delete(params, "memberId")

    with :ok <- authorize_member(conn, :"members.profile.update", member_id),
         {:ok, member} <- member_id |> Membership.pause(attrs) |> rename(:invalid_pause) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:show, member: member)
    end
  end

  @doc """
  POST /members/:memberId/membership/resume
  """
  def resume(conn, %{"memberId" => member_id}) do
    with :ok <- authorize_member(conn, :"members.profile.update", member_id),
         {:ok, member} <- Membership.resume(member_id) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:show, member: member)
    end
  end

  @doc "POST /members/:memberId/billing-portal"
  def billing_portal(conn, %{"memberId" => member_id, "returnUrl" => return_url}) do
    with :ok <- authorize_member(conn, :"members.profile.update", member_id),
         {:ok, url} <-
           member_id
           |> Membership.create_billing_portal_session(return_url)
           |> rename(:invalid_return_url, :billing_portal_failed) do
      json(conn, %{data: %{url: url}})
    end
  end

  def billing_portal(_conn, _params), do: {:error, :invalid_billing_portal}

  @doc """
  POST /members/:memberId/membership/reactivate

  Restricted by the `:membership_reactivate` pipeline (the
  `membership.reactivate` capability: officers with billing authority) —
  there is no self-service fallback because the command mints new Stripe
  charges.
  """
  def reactivate(conn, %{"memberId" => member_id} = params) do
    attrs =
      params
      |> Map.delete("memberId")
      |> Map.put("operatorPrincipalId", conn.assigns.current_session.principal.id)

    with {:ok, result} <-
           member_id
           |> Membership.reactivate(attrs)
           |> rename(:invalid_reactivation, :reactivation_failed) do
      json(conn, %{data: result})
    end
  end

  @doc """
  GET /members/:memberId/membership/reactivation-preview

  Same `:membership_reactivate` restrictions as `reactivate/2` — saved
  payment data must not leak to the broader members-admin list.
  """
  def reactivation_preview(conn, %{"memberId" => member_id}) do
    with {:ok, preview} <-
           member_id
           |> Membership.reactivation_preview()
           |> rename(:invalid_payload, :payment_method_lookup_failed) do
      json(conn, %{data: preview})
    end
  end

  @doc """
  GET /members/:memberId/membership/reactivation-preview/amounts

  Stripe-computed amounts for a reactivation starting on the query param
  `startDate` (ALE-254). Same `:membership_reactivate` restrictions as
  `reactivation_preview/2`. Deliberately independent of that read: a failure
  here degrades to hidden amounts in the UI while the form stays usable.
  """
  def reactivation_amounts_preview(conn, %{"memberId" => member_id} = params) do
    with {:ok, result} <-
           member_id
           |> Membership.reactivation_amounts_preview(params)
           |> rename(:invalid_reactivation_amounts, :cost_preview_failed) do
      json(conn, %{data: result})
    end
  end

  # Owner-scoped: the member themself or a member administrator. Anyone else
  # gets the same 404 as a missing member, so the profile's existence is
  # concealed (ALE-344, matching the frontend's `concealed_resource`).
  defp authorize_member(conn, capability, member_id) do
    Capabilities.authorize(conn.assigns.current_session, capability, %{
      owner_principal_id: member_id
    })
  end

  # `Dhc.Membership` reports one `:invalid_payload` and one `:stripe_error`
  # for every command; each action names its own reason for them so
  # `DhcWeb.MembersHTTP` can keep a distinct detail per action.
  defp rename(result, invalid_payload, stripe_error \\ :stripe_error)
  defp rename({:error, :invalid_payload}, invalid_payload, _), do: {:error, invalid_payload}
  defp rename({:error, :stripe_error}, _, stripe_error), do: {:error, stripe_error}
  defp rename(result, _invalid_payload, _stripe_error), do: result
end
