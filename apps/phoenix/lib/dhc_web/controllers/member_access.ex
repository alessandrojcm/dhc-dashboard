defmodule DhcWeb.MemberAccess do
  @moduledoc """
  The owner-scoped member check shared by `DhcWeb.MembersController` and
  `DhcWeb.MembershipController` (ALE-344).

  `{memberId}` is the owning principal id: the member themself or a holder of
  the capability passes. Anyone else gets `{:error, :not_found}`, the same
  404 as a missing member, so the profile's existence is concealed (matching
  the frontend's `concealed_resource`).
  """

  alias Dhc.Auth.Capabilities

  @spec authorize(Plug.Conn.t(), Capabilities.capability(), String.t()) ::
          :ok | {:error, :not_found | :forbidden | :inactive}
  def authorize(conn, capability, member_id) do
    Capabilities.authorize(conn.assigns.current_session, capability, %{
      owner_principal_id: member_id
    })
  end
end
