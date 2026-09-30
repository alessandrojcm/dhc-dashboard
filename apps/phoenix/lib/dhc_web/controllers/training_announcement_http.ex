defmodule DhcWeb.TrainingAnnouncementHTTP do
  @moduledoc "Shared input and result mapping for the Training Announcement HTTP slices."
  import Plug.Conn
  import Phoenix.Controller

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
  @conflicts %{
    attempted: "This announcement has attempted delivery; retire it instead",
    retired: "This announcement is retired",
    delivery_started: "Delivery has begun; the one-off schedule cannot change",
    concurrent_change: "The announcement changed; reload and try again"
  }

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

  def respond(result, conn, template, status \\ :ok)
  def respond({:ok, _}, conn, :deleted, _), do: send_resp(conn, :no_content, "")

  def respond({:ok, result}, conn, template, status) do
    conn |> put_status(status) |> render(template, result: result)
  end

  def respond({:error, :not_found}, conn, _, _),
    do: error(conn, :not_found, %{detail: "Announcement or exception not found"})

  def respond({:error, :forbidden}, conn, _, _),
    do: error(conn, :forbidden, %{detail: "Insufficient role"})

  def respond({:error, reason}, conn, _, _) when is_map_key(@conflicts, reason) do
    error(conn, :conflict, %{detail: Map.fetch!(@conflicts, reason), code: to_string(reason)})
  end

  def respond({:error, %Ecto.Changeset{} = changeset}, conn, _, _) do
    fields = Ecto.Changeset.traverse_errors(changeset, &interpolate_error/1)

    fields = Map.new(fields, fn {key, errors} -> {public_field(key), errors} end)

    detail =
      Enum.map_join(fields, "; ", fn {key, errors} -> "#{key}: #{Enum.join(errors, ", ")}" end)

    error(conn, :unprocessable_entity, %{detail: detail, fields: fields})
  end

  def respond({:error, errors}, conn, _, _) when is_list(errors) do
    error(conn, :unprocessable_entity, %{detail: Enum.join(errors, "; ")})
  end

  defp public_field(key) do
    internal = to_string(key)
    Enum.find_value(@fields, internal, fn {public, value} -> if value == internal, do: public end)
  end

  defp error_value(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp error_value(value), do: inspect(value)

  defp interpolate_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, text ->
      placeholder = "%{#{key}}"

      if String.contains?(text, placeholder),
        do: String.replace(text, placeholder, error_value(value)),
        else: text
    end)
  end

  defp error(conn, status, errors), do: conn |> put_status(status) |> json(%{errors: errors})
end
