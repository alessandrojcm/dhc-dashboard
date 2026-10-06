defmodule DhcWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs. The body goes through `DhcWeb.Problem`, so an
  unhandled exception renders the same `{errors: {detail}}` shape as every
  other error; the detail is the status message (`"404.json"` → `"Not Found"`).
  """

  alias DhcWeb.Problem

  def render(template, _assigns) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> Problem.body()
  end
end
