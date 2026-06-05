defmodule DhcWeb.StripeWebhooksJSON do
  @moduledoc false

  def render("show.json", %{received: received, event_id: event_id}) do
    %{data: %{received: received, event_id: event_id}}
  end

  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end
end
