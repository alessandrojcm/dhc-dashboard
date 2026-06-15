defmodule DhcWeb.HealthJSON do
  @moduledoc false

  def render("index.json", _assigns) do
    %{data: %{status: "ok"}}
  end
end
