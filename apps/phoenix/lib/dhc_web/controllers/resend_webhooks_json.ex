defmodule DhcWeb.ResendWebhooksJSON do
  @moduledoc false

  def show(%{received: received, handled: handled}) do
    %{data: %{received: received, handled: handled}}
  end
end
