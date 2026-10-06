defmodule DhcWeb.SettingsHTTP do
  @moduledoc """
  The problem fallback for the Settings HTTP slice. A rejected value is a
  message list, so the validator's message (it names the rule broken) is the
  422 `detail`.
  """

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Unknown or non-allowlisted setting key"},
      missing: {500, "Configured setting row not found"},
      no_value: {422, "value is required"}
    }
end
