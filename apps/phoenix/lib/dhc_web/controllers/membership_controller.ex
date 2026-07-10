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

  defp authorize_self_or_admin(conn, member_id) do
    current_user = conn.assigns.current_user

    if current_user.sub == member_id or
         Enum.any?(current_user.roles, &(&1 in @members_admin_roles)) do
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
