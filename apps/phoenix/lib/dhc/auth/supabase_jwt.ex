defmodule Dhc.Auth.SupabaseJwt do
  @moduledoc """
  Verifies Supabase access tokens and extracts the claims Phoenix controllers need.

  Uses `Supabase.Auth.get_claims/3`, which verifies JWTs against Supabase's
  JWKS endpoint when possible and falls back to the Auth server for symmetric
  signing keys.
  """

  @type claims :: %{
          required(:sub) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:roles) => [String.t()],
          optional(:raw) => map()
        }

  @callback verify(String.t()) :: {:ok, claims()} | {:error, term()}

  @spec verify(String.t()) :: {:ok, claims()} | {:error, term()}
  def verify(token) when is_binary(token) and token != "" do
    with {:ok, client} <- client(),
         {:ok, %{claims: claims}} <- Supabase.Auth.get_claims(client, token),
         {:ok, sub} <- required_claim(claims, "sub") do
      {:ok,
       %{
         sub: sub,
         email: claim(claims, "email"),
         roles: roles(claims),
         raw: claims
       }}
    end
  end

  def verify(_token), do: {:error, :missing_token}

  defp client do
    url = Application.get_env(:dhc, :supabase_url)

    key =
      Application.get_env(:dhc, :supabase_anon_key) ||
        Application.get_env(:dhc, :supabase_service_role_key)

    cond do
      is_nil(url) or url == "" -> {:error, :missing_supabase_url}
      is_nil(key) or key == "" -> {:error, :missing_supabase_key}
      true -> {:ok, Supabase.init_client!(url, key)}
    end
  rescue
    error -> {:error, {:supabase_client, error}}
  end

  defp required_claim(claims, name) do
    case claim(claims, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_claim, name}}
    end
  end

  defp roles(claims) do
    claims
    |> claim("app_metadata")
    |> case do
      metadata when is_map(metadata) -> claim(metadata, "roles")
      _ -> []
    end
    |> case do
      roles when is_list(roles) -> Enum.filter(roles, &is_binary/1)
      _ -> []
    end
  end

  defp claim(map, name) when is_map(map) do
    Map.get(map, name) || Map.get(map, String.to_atom(name))
  end
end
