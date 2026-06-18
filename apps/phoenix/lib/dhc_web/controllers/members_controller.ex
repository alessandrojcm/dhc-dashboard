defmodule DhcWeb.MembersController do
  use DhcWeb, :controller

  alias Dhc.Members

  @doc """
  GET /members/insurance-form
  """
  def insurance_form(conn, _params) do
    conn
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:insurance_form, insurance_form: Members.insurance_form())
  end
end
