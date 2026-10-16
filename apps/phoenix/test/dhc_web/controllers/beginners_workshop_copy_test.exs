defmodule DhcWeb.BeginnersWorkshopCopyTest do
  @moduledoc """
  ALE-420: the frontend renders a Beginners' Workshop problem `detail` and
  its field messages verbatim, so none of them may show a backend term.
  Walks the reason table of every `DhcWeb.BeginnersWorkshop*HTTP` family
  and every field message `DhcWeb.BeginnersWorkshopsHTTP.respond/4` builds.
  ALE-425: Staff see every coordinator and Staff Notification too, so it
  also renders each `Commands.NotificationCopy` function with fixture values.

  The banned phrases are `tools/oxlint/anti-slop/shared/backend-terms.json`,
  the list the frontend guards read too.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.Commands.NotificationCopy
  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer
  alias DhcWeb.BeginnersWorkshopsHTTP

  @terms_path Path.expand(
                "../../../../../tools/oxlint/anti-slop/shared/backend-terms.json",
                __DIR__
              )
  @external_resource @terms_path

  defp banned do
    for %{"term" => term, "pattern" => pattern} <-
          @terms_path |> File.read!() |> Jason.decode!() |> Map.fetch!("terms"),
        do: {term, Regex.compile!(pattern, "iu")}
  end

  defp families do
    {:ok, modules} = :application.get_key(:dhc, :modules)

    Enum.filter(modules, fn module ->
      name = inspect(module)
      String.starts_with?(name, "DhcWeb.BeginnersWorkshop") and String.ends_with?(name, "HTTP")
    end)
  end

  defp details(family) do
    for {reason, spec} <- family.problem_config().reasons,
        do: {"#{inspect(family)} #{reason}", elem(spec, 1)}
  end

  defp field_messages do
    reasons = Map.keys(BeginnersWorkshopsHTTP.problem_config().reasons)

    errors =
      Enum.flat_map(reasons, fn reason ->
        [
          BeginnersWorkshopsHTTP.respond({:error, reason}, nil, nil),
          BeginnersWorkshopsHTTP.respond({:error, {:workshop, 0, reason}}, nil, nil)
        ]
      end) ++ [BeginnersWorkshopsHTTP.schedule_attrs(%{})]

    for error <- errors, message <- messages(error), do: {"field message", message}
  end

  # The template editor's `fields.subject` / `fields.body` messages: every
  # Renderer refusal, for every email type.
  defp template_messages do
    paragraph = fn text ->
      %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}
        ]
      }
    end

    attempts = [
      {"", %{"type" => "doc", "content" => []}},
      {"one\ntwo", "not a document"},
      {String.duplicate("x", 500), paragraph.(String.duplicate("x", 3_000))},
      {"{{notAPlaceholder}}", paragraph.("{{notAPlaceholder}}")},
      {42, %{"type" => "doc", "content" => [%{"type" => "unknownBlock"}]}}
    ]

    for type <- EmailType.ids(),
        {subject, body} <- attempts,
        {:error, refusals} <- [Renderer.validate(type, subject, body)],
        {field, _refusal, message} <- refusals,
        do: {"template #{field}", message}
  end

  @workshop %{date: ~D[2026-11-14], start_time: ~T[18:30:00], venue: "St. Andrew's Hall"}

  # Every Notification text, keyed by the function that builds it.
  defp notifications do
    [
      {:batch_sent, NotificationCopy.batch_sent(@workshop.date, 1, 1)},
      {:batch_sent, NotificationCopy.batch_sent(@workshop.date, 2, 5)},
      {:nobody_waiting, NotificationCopy.nobody_waiting(@workshop.date)},
      {:place_paid, NotificationCopy.place_paid("Aoife", @workshop.date)},
      {:place_paid, NotificationCopy.place_paid(nil, @workshop.date)},
      {:staff_assigned, NotificationCopy.staff_assigned("coach", @workshop)},
      {:staff_assigned, NotificationCopy.staff_assigned("assistant", @workshop)},
      {:staff_unassigned, NotificationCopy.staff_unassigned(@workshop)},
      {:rescheduled, NotificationCopy.rescheduled(@workshop)},
      {:cancelled, NotificationCopy.cancelled(@workshop)},
      {:reply_waiting, NotificationCopy.reply_waiting(Ecto.UUID.generate())}
    ] ++
      for follow_up <- NotificationCopy.refund_follow_ups(),
          {name, date} <- [{"Aoife", @workshop.date}, {nil, nil}],
          do: {:refund_failed, NotificationCopy.refund_failed("€35.00", name, date, follow_up)}
  end

  defp messages({:error, _reason, fields}), do: fields |> Map.values() |> List.flatten()
  defp messages({:error, [_ | _] = messages}), do: messages
  defp messages(_error), do: []

  defp offences(copy) do
    for {where, text} <- copy,
        {term, pattern} <- banned(),
        Regex.match?(pattern, text),
        do: "#{where}: #{inspect(term)} in #{inspect(text)}"
  end

  test "every Beginners' Workshop family is walked" do
    assert DhcWeb.BeginnersWorkshopsHTTP in families()
    assert DhcWeb.BeginnersWorkshopIntakeHTTP in families()
    assert DhcWeb.BeginnersWorkshopEmailTemplatesHTTP in families()
  end

  test "no problem detail shows a backend term" do
    assert families() |> Enum.flat_map(&details/1) |> offences() == []
  end

  test "no field message shows a backend term" do
    copy = field_messages() ++ template_messages()
    assert {"template subject", "can't be blank"} in copy
    assert Enum.any?(copy, &match?({"field message", _}, &1))
    assert offences(copy) == []
  end

  test "every Notification builder is rendered" do
    builders =
      for {name, _arity} <- NotificationCopy.__info__(:functions),
          name != :refund_follow_ups,
          uniq: true,
          do: name

    assert Enum.sort(builders) == notifications() |> Keyword.keys() |> Enum.uniq() |> Enum.sort()
  end

  test "no Notification shows a backend term" do
    copy = for {builder, text} <- notifications(), do: {"notification #{builder}", text}
    assert offences(copy) == []
  end

  # ALE-412: EmailType owns each type's staff label, which the dashboard
  # shows verbatim (Email templates, the console's email log).
  test "no Intake Email label shows a backend term" do
    labels = for type <- EmailType.all(), do: {"email label #{type.id}", type.label}
    assert offences(labels) == []
  end

  test "the banned phrases match whole phrases only" do
    assert offences([{"x", "Their Intakes stay"}, {"x", "Could not pause Batches"}]) != []

    assert offences([{"x", "Seated in the workshop place, offer round and workshop credit"}]) ==
             []
  end
end
