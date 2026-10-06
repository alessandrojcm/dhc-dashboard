defmodule DhcWeb.AuthSessionJSON do
  @moduledoc """
  JSON renderers for the Phoenix-session auth API (ALE-165).

  The session projection is the spec's
  `{ principal: { id, email }, roles, capabilities }`. `capabilities` are the
  wire names `Dhc.Auth.Capabilities` grants the roles (ALE-344); the
  dashboard applies only ownership and navigation on top. No `is_active`, no
  raw token, no Supabase `sub`/bearer/refresh compatibility.
  """

  def session(%{session: %{principal: principal, roles: roles, capabilities: capabilities}}) do
    %{
      data: %{
        principal: %{id: principal.id, email: principal.email},
        roles: roles,
        capabilities: capabilities
      }
    }
  end

  def sent(_assigns) do
    # Non-enumerating: identical for known, unknown, inactive, and rate-
    # limited addresses. The rate-limit plug returns its own 200 with this
    # same shape; we centralize the body here so the two paths cannot drift.
    %{data: %{sent: true}}
  end
end
