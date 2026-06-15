defmodule DhcWeb.Plugs.RequireAuth do
  @moduledoc """
  Requires a valid Supabase bearer token and, optionally, one of a set of roles.

  Verified claims are assigned to `conn.assigns.current_user`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    required_roles = Keyword.get(opts, :roles, [])

    with {:ok, token} <- bearer_token(conn),
         {:ok, claims} <- verifier().verify(token),
         :ok <- authorize(claims, required_roles) do
      assign(conn, :current_user, claims)
    else
      {:error, :missing_token} -> unauthorized(conn, "Missing bearer token")
      {:error, :forbidden} -> forbidden(conn, "Insufficient role")
      {:error, reason} -> unauthorized(conn, reason)
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> case do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      ["bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp authorize(_claims, []), do: :ok

  defp authorize(%{roles: roles}, required_roles) do
    if Enum.any?(roles, &(&1 in required_roles)), do: :ok, else: {:error, :forbidden}
  end

  defp verifier, do: Application.get_env(:dhc, :auth_verifier, Dhc.Auth.SupabaseJwt)

  defp unauthorized(conn, reason) do
    Logger.warning("[auth] request rejected: #{inspect(reason)}")

    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "Unauthorized"}})
    |> halt()
  end

  defp forbidden(conn, detail) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: detail}})
    |> halt()
  end
end
