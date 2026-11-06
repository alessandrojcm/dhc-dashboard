defmodule Dhc.IntakeEmailEndTimeMigrationTest do
  use Dhc.DataCase, async: false

  alias Dhc.BeginnersWorkshops.IntakeEmails
  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer

  @migration Dhc.Repo.Migrations.AddEndTimeToBeginnersWorkshopEmailTemplates
  @version 20_261_106_084_926

  setup_all do
    Code.require_file(
      "priv/repo/migrations/#{@version}_add_end_time_to_beginners_workshop_email_templates.exs"
    )

    :ok
  end

  setup do
    replace_body("contact_pay", custom_body())
    replace_body("contact_confirm", body_with_end_time())

    :ok
  end

  test "preserves custom nested marked copy, keeps existing end times singular, and loads map bodies through the template seam" do
    migrate(:up)

    custom = IntakeEmails.get_template!("contact_pay")
    assert is_map(custom.body)
    assert custom.body == expected_custom_body()

    existing = IntakeEmails.get_template!("contact_confirm")
    assert is_map(existing.body)
    assert IntakeEmails.get_template!("contact_confirm").body == body_with_end_time()

    migrate(:up)
    assert IntakeEmails.get_template!("contact_pay").body == expected_custom_body()
    assert IntakeEmails.get_template!("contact_confirm").body == body_with_end_time()

    migrate(:down)
    assert IntakeEmails.get_template!("contact_pay").body == expected_custom_body()
    assert IntakeEmails.get_template!("contact_confirm").body == body_with_end_time()
  end

  test "adds an end-time paragraph when custom copy has no start-time chip" do
    original = doc([p([text("Bring water.")])])
    replace_body("pre_workshop", original)
    migrate(:up)

    assert IntakeEmails.get_template!("pre_workshop").body ==
             doc([
               p([text("Bring water.")]),
               p([text("The workshop ends at "), placeholder("endTime"), text(".")])
             ])
  end

  test "refuses to invalidate an at-limit custom template or truncate its copy" do
    original = doc([p([text(String.duplicate("a", 1988)), placeholder("startTime")])])
    assert {:ok, %{length: 2000, fits?: true}} = Renderer.measure("contact_pay", original)
    replace_body("contact_pay", original)

    assert_raise RuntimeError, ~r/contact_pay is 2006 characters.*shorten it and rerun/, fn ->
      migrate(:up)
    end

    assert IntakeEmails.get_template!("contact_pay").body == original
  end

  defp custom_body do
    doc([
      quote_block([
        p([text("Custom: "), placeholder("startTime", [%{"type" => "bold"}]), text(" only")])
      ])
    ])
  end

  defp expected_custom_body do
    doc([
      quote_block([
        p([
          text("Custom: "),
          placeholder("startTime", [%{"type" => "bold"}]),
          text("–"),
          placeholder("endTime"),
          text(" only")
        ])
      ])
    ])
  end

  defp body_with_end_time do
    doc([p([placeholder("startTime"), text("–"), placeholder("endTime")])])
  end

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp p(content), do: %{"type" => "paragraph", "content" => content}
  defp quote_block(content), do: %{"type" => "blockquote", "content" => content}
  defp text(value), do: %{"type" => "text", "text" => value}

  defp placeholder(name, marks \\ [])
  defp placeholder(name, []), do: %{"type" => "placeholder", "attrs" => %{"name" => name}}

  defp placeholder(name, marks),
    do: Map.put(%{"type" => "placeholder", "attrs" => %{"name" => name}}, "marks", marks)

  defp migrate(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      @migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp replace_body(type, body) do
    type
    |> IntakeEmails.get_template!()
    |> Ecto.Changeset.change(body: body)
    |> Repo.update!()
  end
end
