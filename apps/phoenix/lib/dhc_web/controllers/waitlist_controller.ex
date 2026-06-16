defmodule DhcWeb.WaitlistController do
  use DhcWeb, :controller

  alias Dhc.Waitlist

  @doc """
  GET /waitlist/status
  """
  def index(conn, _params) do
    conn
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:status, status: Waitlist.status())
  end
end
