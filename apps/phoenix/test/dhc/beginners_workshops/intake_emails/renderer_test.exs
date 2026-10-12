defmodule Dhc.BeginnersWorkshops.IntakeEmails.RendererTest do
  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer

  # Shared with the dashboard's template counter, so the two measures cannot drift.
  @fixtures_path Path.expand(
                   "../../../../../../packages/email-templates/fixtures/intake-email-measure.json",
                   __DIR__
                 )
  @external_resource @fixtures_path
  @fixtures @fixtures_path |> File.read!() |> Jason.decode!()

  defp doc(blocks), do: %{"type" => "doc", "content" => blocks}
  defp p(content), do: %{"type" => "paragraph", "content" => content}
  defp t(text), do: %{"type" => "text", "text" => text}
  defp ph(name), do: %{"type" => "placeholder", "attrs" => %{"name" => name}}

  @values %{
    "firstName" => "Aoife",
    "date" => "Saturday 14 November 2026",
    "startTime" => "10:00",
    "venue" => "St. Michan's Hall",
    "fee" => "€50.00",
    "windowEnd" => "Sunday 8 November 2026, 23:59",
    "paymentCutoff" => "Wednesday 11 November 2026, 23:59",
    "refundAmount" => "€50.00"
  }

  describe "the shared measure fixtures" do
    test "agree with the email type table on the limit and every maximum" do
      assert @fixtures["limit"] == Renderer.limit()
      assert @fixtures["maxima"] == EmailType.maxima()

      assert @fixtures["placeholders"] ==
               Map.new(EmailType.all(), &{&1.id, &1.placeholders})
    end

    for %{"name" => name} = fixture <- @fixtures["cases"] do
      @fixture fixture
      test "measures: #{name}" do
        %{"emailType" => type, "body" => body} = @fixture

        assert {:ok, %{html: html, length: length, fits?: fits?}} = Renderer.measure(type, body)
        assert html == @fixture["expectedHtml"]
        assert length == @fixture["expectedLength"]
        assert fits? == @fixture["fits"]
      end
    end

    for %{"name" => name} = fixture <- @fixtures["refusals"] do
      @fixture fixture
      test "refuses: #{name}" do
        %{"emailType" => type, "body" => body, "placeholders" => names} = @fixture

        assert {:error, {:placeholder_not_allowed, ^names}} = Renderer.measure(type, body)
      end
    end
  end

  describe "render_body/3" do
    test "substitutes placeholder values HTML-escaped" do
      body = doc([p([t("Hi "), ph("firstName"), t(", see you at "), ph("venue")])])
      values = %{@values | "firstName" => ~s{<img src=x onerror="alert(1)">&Co}}

      assert {:ok, html} = Renderer.render_body("pre_workshop", body, values)

      assert html ==
               "<p>Hi &lt;img src=x onerror=&quot;alert(1)&quot;&gt;&amp;Co, " <>
                 "see you at St. Michan&#39;s Hall</p>"
    end

    test "escapes text nodes and never parses HTML in them" do
      body = doc([p([t("<script>alert('x')</script>")])])

      assert {:ok, "<p>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</p>"} =
               Renderer.render_body("declined", body, @values)
    end

    test "writes no inline styles" do
      body =
        doc([
          %{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [t("Hello")]},
          p([%{"type" => "text", "text" => "bold", "marks" => [%{"type" => "bold"}]}])
        ])

      assert {:ok, html} = Renderer.render_body("follow_up", body, @values)
      refute html =~ "style"
    end

    test "leaves typed {{braces}} as literal text" do
      body = doc([p([t("Hi {{firstName}}")])])

      assert {:ok, "<p>Hi {{firstName}}</p>"} = Renderer.render_body("follow_up", body, @values)
    end

    test "refuses a placeholder the email type cannot fill" do
      body = doc([p([ph("firstName"), ph("refundAmount"), ph("venue")])])

      assert {:error, {:placeholder_not_allowed, ["refundAmount", "venue"]}} =
               Renderer.render_body("follow_up", body, @values)
    end

    test "refuses a missing value rather than rendering a blank" do
      body = doc([p([ph("firstName")])])

      assert {:error, {:missing_values, ["firstName"]}} =
               Renderer.render_body("follow_up", body, Map.delete(@values, "firstName"))
    end

    test "refuses content outside the vocabulary" do
      assert {:error, {:invalid_body, "contains unsupported content (image)"}} =
               Renderer.render_body("follow_up", doc([%{"type" => "image"}]), @values)
    end

    test "refuses a malformed placeholder node" do
      body = doc([p([%{"type" => "placeholder", "attrs" => %{}}])])

      assert {:error, {:invalid_body, "has a malformed placeholder"}} =
               Renderer.render_body("follow_up", body, @values)
    end
  end

  describe "render_subject/3" do
    test "fills {{placeholder}} tokens with plain-text values" do
      assert {:ok, "A place on Saturday 14 November 2026 for Aoife & co"} =
               Renderer.render_subject(
                 "contact_pay",
                 "A place on {{date}} for {{firstName}} & co",
                 @values
               )
    end

    test "refuses tokens the email type cannot fill, including unknown ones" do
      assert {:error, {:placeholder_not_allowed, ["venue", "coach"]}} =
               Renderer.render_subject("follow_up", "{{venue}} with {{coach}}", @values)
    end
  end

  describe "validate/3" do
    test "accepts a template that only uses its own placeholders" do
      assert :ok =
               Renderer.validate(
                 "withdrawn_refunded",
                 "We've refunded {{refundAmount}}",
                 doc([p([t("Hi "), ph("firstName")])])
               )
    end

    test "reports subject and body problems separately" do
      assert {:error, errors} =
               Renderer.validate(
                 "withdrawn_forfeited",
                 "Your workshop on {{date}}",
                 doc([p([ph("refundAmount")])])
               )

      assert {:subject, :placeholder_not_allowed, "uses {{date}}, which this email can't fill"} in errors

      assert {:body, :placeholder_not_allowed,
              "uses {{refundAmount}}, which this email can't fill"} in errors
    end

    test "refuses a body whose worst-case render exceeds the limit" do
      body = doc([p(List.duplicate(ph("venue"), 25))])

      assert {:error,
              [
                {:body, :template_too_long,
                 "is 2007 characters with every placeholder at its longest; the limit is 2000"}
              ]} =
               Renderer.validate("contact_pay", "Subject", body)
    end

    test "refuses a blank, multi-line or overlong subject" do
      body = doc([p([t("Hi")])])

      for subject <- ["", "  ", "Line\nbreak", String.duplicate("a", 201)] do
        assert {:error, [{:subject, :invalid_template, _}]} =
                 Renderer.validate("declined", subject, body)
      end
    end
  end
end
