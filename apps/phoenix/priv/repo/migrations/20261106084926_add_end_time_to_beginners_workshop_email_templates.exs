defmodule Dhc.Repo.Migrations.AddEndTimeToBeginnersWorkshopEmailTemplates do
  @moduledoc """
  ALE-431: lets schedule-bearing Intake Email templates show an end time.

  The template body is coordinator-owned copy: add the end after an existing
  `startTime` chip, or append an end-time sentence when it is absent. Existing
  nodes, including customised wording and marks, stay untouched; a body that
  already has an `endTime` chip is left alone. An augmentation that would exceed
  the delivery limit stops the migration rather than truncating custom copy.
  """

  use Ecto.Migration

  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer

  @schedule_types ~w(contact_pay contact_confirm place_confirmed_paid place_confirmed_carried pre_workshop rescheduled)

  def up do
    result =
      repo().query!(
        "SELECT email_type, body FROM beginners_workshop_email_templates WHERE email_type = ANY($1)",
        [@schedule_types]
      )

    Enum.each(result.rows, fn [type, body] -> update_template_body(type, body) end)
  end

  # This data migration intentionally preserves coordinator customisation, so
  # it cannot safely remove a chip that may have existed before this release.
  def down, do: :ok

  defp placeholder?(%{"type" => "placeholder", "attrs" => %{"name" => name}}, name), do: true

  defp placeholder?(value, name) when is_map(value),
    do: Enum.any?(value, fn {_key, child} -> placeholder?(child, name) end)

  defp placeholder?(values, name) when is_list(values),
    do: Enum.any?(values, &placeholder?(&1, name))

  defp placeholder?(_value, _name), do: false

  defp update_template_body(type, body) do
    with false <- placeholder?(body, "endTime"),
         {:ok, body} <- add_end_time_after_start_time(body),
         :ok <- fits?(type, body) do
      repo().query!(
        "UPDATE beginners_workshop_email_templates SET body = $1::jsonb, updated_at = NOW() WHERE email_type = $2",
        [body, type]
      )
    end
  end

  defp add_end_time_after_start_time(body) do
    case add_to_nodes(Map.get(body, "content", [])) do
      {:ok, content} -> {:ok, Map.put(body, "content", content)}
      :not_found -> {:ok, append_end_time_paragraph(body)}
    end
  end

  defp append_end_time_paragraph(%{"content" => content} = body) when is_list(content) do
    Map.put(
      body,
      "content",
      content ++
        [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "The workshop ends at "},
              end_time_placeholder(),
              %{"type" => "text", "text" => "."}
            ]
          }
        ]
    )
  end

  defp fits?(type, body) do
    case Renderer.measure(type, body) do
      {:ok, %{fits?: true}} ->
        :ok

      {:ok, %{length: length}} ->
        raise "Intake Email template #{type} is #{length} characters after adding end time; shorten it and rerun this migration"

      {:error, reason} ->
        raise "Intake Email template #{type} cannot add end time: #{inspect(reason)}"
    end
  end

  defp add_to_nodes([]), do: :not_found

  defp add_to_nodes([node | rest]) do
    case add_to_node(node) do
      {:ok, node} ->
        {:ok, List.flatten([node | rest])}

      :not_found ->
        case add_to_nodes(rest) do
          {:ok, rest} -> {:ok, [node | rest]}
          :not_found -> :not_found
        end
    end
  end

  defp add_to_node(%{"type" => "placeholder", "attrs" => %{"name" => "startTime"}} = node),
    do: {:ok, [node, %{"type" => "text", "text" => "–"}, end_time_placeholder()]}

  defp add_to_node(%{"content" => content} = node) do
    case add_to_nodes(content) do
      {:ok, content} -> {:ok, Map.put(node, "content", content)}
      :not_found -> :not_found
    end
  end

  defp add_to_node(_node), do: :not_found

  defp end_time_placeholder,
    do: %{"type" => "placeholder", "attrs" => %{"name" => "endTime"}}
end
