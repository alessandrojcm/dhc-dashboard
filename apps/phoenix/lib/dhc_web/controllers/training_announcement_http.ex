defmodule DhcWeb.TrainingAnnouncementHTTP do
  @moduledoc """
  Shared input mapping and the problem fallback for the Training Announcement
  HTTP slices. Controllers declare `action_fallback DhcWeb.TrainingAnnouncementHTTP`;
  `respond/4` renders a success and hands any error back to the fallback.
  """
  import Plug.Conn
  import Phoenix.Controller

  # Public camelCase request field → internal attribute.
  @fields %{
    "kind" => "kind",
    "weekday" => "weekday",
    "oneOffDate" => "one_off_date",
    "postTime" => "post_time",
    "title" => "title",
    "message" => "message",
    "mentionEveryone" => "mention_everyone",
    "date" => "date",
    "fromDate" => "from_date",
    "toDate" => "to_date"
  }

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Announcement or exception not found"},
      attempted: {409, "This announcement has attempted delivery; retire it instead"},
      retired: {409, "This announcement is retired"},
      delivery_started: {409, "Delivery has begun; the one-off schedule cannot change"},
      concurrent_change: {409, "The announcement changed; reload and try again"}
    },
    fields: Map.new(@fields, fn {public, internal} -> {internal, public} end)

  def actor_id(conn), do: conn.assigns.current_session.principal.id

  # Accept only the public camelCase vocabulary; routing ids and server-owned
  # lifecycle fields are never cast from the request body.
  def attrs(params) do
    for {public, internal} <- @fields,
        Map.has_key?(params, public),
        into: %{},
        do: {internal, Map.fetch!(params, public)}
  end

  def copy_attrs(params) do
    case Map.get(params, "mentionEveryone") do
      mention when is_boolean(mention) -> {:ok, attrs(params)}
      _ -> {:error, ["mentionEveryone must be a boolean"]}
    end
  end

  @doc "Renders an `{:ok, result}`; any error is returned for the action fallback."
  def respond(result, conn, template, status \\ :ok)
  def respond({:ok, _}, conn, :deleted, _), do: send_resp(conn, :no_content, "")

  def respond({:ok, result}, conn, template, status) do
    conn |> put_status(status) |> render(template, result: result)
  end

  def respond(error, _conn, _template, _status), do: error
end
