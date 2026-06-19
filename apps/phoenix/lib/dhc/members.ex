defmodule Dhc.Members do
  @moduledoc """
  Members context functions used by Phoenix API controllers.

  This is the context shell introduced by the Members read migration
  (issue #123). Later slices (member list, analytics) extend this module.
  """

  import Ecto.Query

  alias Dhc.Repo

  @insurance_form_link_key "hema_insurance_form_link"

  @doc """
  Returns the member insurance form link.

  Reads the `hema_insurance_form_link` settings row and exposes it as a
  domain-shaped value, not a generic settings proxy. A missing row or an
  empty/whitespace-only value is reported as `nil` so callers can render
  "not configured" without knowing the storage shape.

  RBAC is enforced at the controller layer (any authenticated user), mirroring
  the `settings` SELECT RLS policy (`USING (true)` for authenticated).
  """
  @spec insurance_form() :: %{link: String.t() | nil}
  def insurance_form do
    %{link: insurance_form_link()}
  end

  @spec insurance_form_link() :: String.t() | nil
  defp insurance_form_link do
    from(s in "settings",
      where: field(s, :key) == ^@insurance_form_link_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> normalize_link()
  end

  defp normalize_link(nil), do: nil

  defp normalize_link(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
