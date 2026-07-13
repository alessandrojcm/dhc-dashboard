defmodule Dhc.Stripe.LookupKeys do
  @moduledoc """
  Centralizes Stripe price lookup keys used for membership products.

  Deployments may override these with the optional
  `:stripe_membership_lookup_keys` application config. Missing or blank values
  fall back to the current Stripe lookup keys.
  """

  @config_key :stripe_membership_lookup_keys
  @defaults %{
    monthly: "standard_membership_fee",
    annual: "annual_membership_fee_revised"
  }

  @spec monthly() :: String.t()
  def monthly, do: get(:monthly)

  @spec annual() :: String.t()
  def annual, do: get(:annual)

  @spec all() :: [String.t()]
  def all do
    [:monthly, :annual]
    |> Enum.map(&get/1)
    |> Enum.uniq()
  end

  defp get(kind) when kind in [:monthly, :annual] do
    @config_key
    |> configured_lookup_keys()
    |> lookup(kind)
    |> fallback_blank(Map.fetch!(@defaults, kind))
  end

  defp configured_lookup_keys(config_key) do
    :dhc
    |> Application.get_env(config_key, %{})
    |> normalize_config()
  end

  defp normalize_config(config) when is_list(config), do: Map.new(config)
  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(_config), do: %{}

  defp lookup(config, kind) do
    Map.get(config, kind) || Map.get(config, Atom.to_string(kind))
  end

  defp fallback_blank(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      value -> value
    end
  end

  defp fallback_blank(_value, fallback), do: fallback
end
