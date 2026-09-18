defmodule DhcWeb.OpenApiVerifier do
  @moduledoc """
  Auth verifier for controller contract tests.

  Tests call `install/1` instead of nesting a `Verifier` module. Tokens of
  the form `<role>-token` resolve through the installed spec; anything else
  is `{:error, :invalid_token}` unless listed under `:tokens`.
  """

  @type claims :: %{
          required(:sub) => String.t(),
          required(:email) => String.t(),
          required(:roles) => [String.t()],
          required(:raw) => map()
        }

  @spec install(keyword()) :: term()
  def install(opts) when is_list(opts) do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :openapi_verifier, Map.new(opts))
    Application.put_env(:dhc, :auth_verifier, __MODULE__)
    original
  end

  @spec restore(term()) :: :ok
  def restore(original) do
    Application.delete_env(:dhc, :openapi_verifier)

    if original do
      Application.put_env(:dhc, :auth_verifier, original)
    else
      Application.delete_env(:dhc, :auth_verifier)
    end

    :ok
  end

  @spec principal_id(String.t()) :: String.t()
  def principal_id(role) when is_binary(role) do
    spec()
    |> Map.get(:role_subs, %{})
    |> Map.fetch!(role)
  end

  @spec verify(term()) :: {:ok, claims()} | {:error, :invalid_token}
  def verify(token) when is_binary(token) do
    spec = spec()
    tokens = Map.get(spec, :tokens, %{})

    cond do
      is_map_key(tokens, token) ->
        claims(tokens[token])

      String.ends_with?(token, "-token") ->
        verify_role(spec, String.replace_suffix(token, "-token", ""))

      true ->
        {:error, :invalid_token}
    end
  end

  def verify(_token), do: {:error, :invalid_token}

  defp verify_role(spec, role) do
    allowed = Map.get(spec, :roles)
    accept_any? = Map.get(spec, :accept_any_role, false)

    if accept_any? or (is_list(allowed) and role in allowed) do
      {:ok,
       %{
         sub: sub_for(spec, role),
         email: email_for(spec, role),
         roles: [role],
         raw: %{}
       }}
    else
      {:error, :invalid_token}
    end
  end

  defp sub_for(spec, role) do
    role_subs = Map.get(spec, :role_subs, %{})

    cond do
      is_map_key(role_subs, role) -> role_subs[role]
      spec[:generate_sub] -> Ecto.UUID.generate()
      spec[:actor_id] -> spec.actor_id
      true -> Ecto.UUID.generate()
    end
  end

  defp email_for(spec, role) do
    case spec do
      %{role_email: email} when is_binary(email) -> email
      _ -> "#{role}@example.com"
    end
  end

  defp claims(%{sub: sub, email: email, roles: roles} = token) do
    {:ok,
     %{
       sub: sub,
       email: email,
       roles: roles,
       raw: Map.get(token, :raw, %{})
     }}
  end

  defp claims(%{email: email, roles: roles}) do
    {:ok, %{sub: Ecto.UUID.generate(), email: email, roles: roles, raw: %{}}}
  end

  # Process-wide Application env. Safe only while every suite that
  # calls `install/1` is `async: false` — a parallel suite would race
  # the spec and see another test's tokens.
  defp spec, do: Application.get_env(:dhc, :openapi_verifier, %{})
end
