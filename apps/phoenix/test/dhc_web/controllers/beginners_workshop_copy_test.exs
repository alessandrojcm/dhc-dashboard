defmodule DhcWeb.BeginnersWorkshopCopyTest do
  @moduledoc """
  ALE-420: the frontend renders a Beginners' Workshop problem `detail` and
  its field messages verbatim, so none of them may show a backend term.
  Walks the reason table of every `DhcWeb.BeginnersWorkshop*HTTP` family
  and every field message `DhcWeb.BeginnersWorkshopsHTTP.respond/4` builds.

  The banned phrases mirror `tools/oxlint/anti-slop/shared/backend-terms.ts`
  (the frontend guard); keep the two lists in step.
  """

  use ExUnit.Case, async: true

  alias DhcWeb.BeginnersWorkshopsHTTP

  @banned [
    {"Intake", ~r/\bintakes?\b/i},
    {"Batch", ~r/\bbatch(?:es)?\b/i},
    {"Carried Fee", ~r/\bcarried[\s-]+fees?\b/i},
    {"Payment Cutoff", ~r/\bpayment[\s-]+cut-?offs?\b/i},
    {"Finalisation", ~r/\bfinali[sz]ations?\b/i},
    {"Seat Hold", ~r/\bseat[\s-]+holds?\b/i},
    {"seat", ~r/\bseats?\b/i},
    {"Fast-track", ~r/\bfast[\s-]?track(?:s|ed|ing)?\b/i},
    {"Waitlist entry", ~r/\bwaitlist[\s-]+entr(?:y|ies)\b/i},
    {"contact-from", ~r/\bcontact[\s-]+from\b/i},
    {"Console", ~r/\bconsoles?\b/i}
  ]

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

  defp messages({:error, _reason, fields}), do: fields |> Map.values() |> List.flatten()
  defp messages({:error, [_ | _] = messages}), do: messages
  defp messages(_error), do: []

  defp offences(copy) do
    for {where, text} <- copy,
        {term, pattern} <- @banned,
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
    copy = field_messages()
    assert copy != []
    assert offences(copy) == []
  end

  test "the banned phrases match whole phrases only" do
    assert offences([{"x", "Their Intakes stay"}, {"x", "Could not pause Batches"}]) != []

    assert offences([{"x", "Seated in the workshop place, offer round and workshop credit"}]) ==
             []
  end
end
