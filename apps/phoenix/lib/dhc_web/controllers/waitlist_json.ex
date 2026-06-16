defmodule DhcWeb.WaitlistJSON do
  @moduledoc false

  def render("status.json", %{status: status}) do
    %{data: %{isOpen: status.is_open}}
  end
end
