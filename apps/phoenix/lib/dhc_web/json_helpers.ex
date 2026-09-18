defmodule DhcWeb.JSONHelpers do
  @moduledoc """
  Shared JSON rendering helpers for controller views.

  Datetimes on the wire are second-precision ISO-8601. Postgres timestamptz
  columns may load as either `%DateTime{}` or `%NaiveDateTime{}` depending
  on the adapter, so both are accepted.
  """

  @spec serialize_datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def serialize_datetime(nil), do: nil

  def serialize_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def serialize_datetime(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
