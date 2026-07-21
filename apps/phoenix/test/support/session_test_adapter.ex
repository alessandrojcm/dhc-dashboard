defmodule DhcWeb.SessionTestAdapter do
  @moduledoc false

  import Plug.Conn

  alias Dhc.Auth.Principal

  def projection(conn) do
    with verifier when not is_nil(verifier) <- Application.get_env(:dhc, :auth_verifier),
         {:ok, token} <- bearer_token(conn),
         {:ok, claims} <- verifier.verify(token) do
      principal = %Principal{id: claims.sub, email: claims.email}
      {:ok, nil, %{principal: principal, roles: claims.roles, is_active: true}}
    else
      nil -> {:error, :missing_token}
      {:error, :missing_token} -> {:error, :missing_token}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      ["bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end
end
