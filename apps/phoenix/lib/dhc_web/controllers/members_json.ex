defmodule DhcWeb.MembersJSON do
  @moduledoc false

  def render("insurance_form.json", %{insurance_form: insurance_form}) do
    %{data: %{link: insurance_form.link}}
  end
end
