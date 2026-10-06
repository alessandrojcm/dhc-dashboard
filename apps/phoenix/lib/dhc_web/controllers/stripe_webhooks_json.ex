defmodule DhcWeb.StripeWebhooksJSON do
  @moduledoc false

  def show(%{received: received, event_id: event_id}) do
    %{data: %{received: received, event_id: event_id}}
  end
end
