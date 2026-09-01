defmodule DhcWeb.SettingsJSON do
  @moduledoc false

  def render("index.json", %{settings: settings}) do
    %{data: %{settings: Enum.map(settings, &render_setting/1)}}
  end

  def render("show.json", %{setting: setting}) do
    %{data: render_setting(setting)}
  end

  def render("precondition_failed.json", %{setting: setting}) do
    %{data: render_setting(setting), errors: %{detail: "version precondition failed"}}
  end

  defp render_setting(%{
         key: key,
         value: value,
         description: description,
         lock_version: lock_version,
         updated_at: updated_at
       }) do
    %{
      key: key,
      value: value,
      description: description,
      lockVersion: lock_version,
      updatedAt: serialize_datetime(updated_at)
    }
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
