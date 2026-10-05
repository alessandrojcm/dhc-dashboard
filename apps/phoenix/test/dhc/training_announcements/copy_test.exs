defmodule Dhc.TrainingAnnouncements.CopyTest do
  use ExUnit.Case, async: true

  alias Dhc.TrainingAnnouncements.Copy

  @thursday_25_sep_2025 ~D[2025-09-25]

  describe "format_date/1 and format_weekday/1" do
    test "formats a Thursday as 'Thursday 25 September'" do
      assert Copy.format_weekday(@thursday_25_sep_2025) == "Thursday"
      assert Copy.format_date(@thursday_25_sep_2025) == "Thursday 25 September"
    end

    test "formats a Sunday without zero-padding the day" do
      assert Copy.format_date(~D[2026-09-27]) == "Sunday 27 September"
      assert Copy.format_date(~D[2026-10-04]) == "Sunday 4 October"
    end
  end

  describe "validate_message/1" do
    test "accepts the full token vocabulary" do
      assert :ok =
               Copy.validate_message("{{title}} on {{date}} ({{weekday}})! Who is coming?")
    end

    test "accepts copy with no tokens" do
      assert :ok = Copy.validate_message("Plain message, no tokens.")
    end

    test "rejects an unknown token" do
      assert {:error, errors} = Copy.validate_message("See you at {{startTime}}!")
      assert Enum.any?(errors, &(&1 =~ "startTime"))
    end

    test "rejects a malformed token" do
      assert {:error, errors} = Copy.validate_message("See you at {{date!")
      assert errors != []
    end

    test "rejects an empty token" do
      assert {:error, _} = Copy.validate_message("See you {{}}!")
    end

    test "rejects a stray closing brace pair" do
      assert {:error, _} = Copy.validate_message("See you date}}!")
    end

    test "rejects holiday-only tokens in announcement copy" do
      assert {:error, errors} = Copy.validate_message("No training for {{holidayName}}!")
      assert Enum.any?(errors, &(&1 =~ "holidayName"))
    end
  end

  describe "validate_title/1" do
    test "accepts date and weekday tokens" do
      assert :ok = Copy.validate_title("Roll call {{date}}")
      assert :ok = Copy.validate_title("Sparring {{weekday}}")
    end

    test "rejects a self-referential title token" do
      assert {:error, errors} = Copy.validate_title("{{title}} tonight")
      assert Enum.any?(errors, &(&1 =~ "title"))
    end
  end

  describe "render_title/2" do
    test "renders the bot-compatible thread name" do
      assert {:ok, "Roll call Thursday 25 September"} =
               Copy.render_title("Roll call {{date}}", @thursday_25_sep_2025)
    end

    test "rejects a title that renders past 100 characters" do
      long = String.duplicate("x", 95) <> " {{date}}"
      assert {:error, errors} = Copy.render_title(long, @thursday_25_sep_2025)
      assert Enum.any?(errors, &(&1 =~ "100"))
    end

    test "rejects invalid templates without rendering" do
      assert {:error, _} = Copy.render_title("See you {{startTime}}", @thursday_25_sep_2025)
    end
  end

  describe "render_message/3" do
    test "renders all tokens from the resolved title and date" do
      assert {:ok, rendered} =
               Copy.render_message(
                 "{{title}}! It's {{weekday}} ({{date}})!",
                 %{date: @thursday_25_sep_2025, title: "Roll call"},
                 false
               )

      assert rendered == "Roll call! It's Thursday (Thursday 25 September)!"
    end

    test "prepends the @everyone line only when the toggle is on" do
      assert {:ok, ping} =
               Copy.render_message("Who is coming?", %{date: @thursday_25_sep_2025}, true)

      assert ping == "@everyone\nWho is coming?"

      assert {:ok, quiet} =
               Copy.render_message("Who is coming?", %{date: @thursday_25_sep_2025}, false)

      assert quiet == "Who is coming?"
    end

    test "renders free text literally, including typed mentions" do
      assert {:ok, rendered} =
               Copy.render_message(
                 "Hey @everyone! @coach see {{date}}",
                 %{date: @thursday_25_sep_2025},
                 false
               )

      assert rendered == "Hey @everyone! @coach see Thursday 25 September"
    end

    test "counts the @everyone line against the 2000-character limit" do
      body = String.duplicate("x", 1992)

      assert {:error, errors} =
               Copy.render_message(body, %{date: @thursday_25_sep_2025}, true)

      assert Enum.any?(errors, &(&1 =~ "2,000"))
    end

    test "accepts a message at exactly the limit" do
      body = String.duplicate("x", 2000)

      assert {:ok, ^body} =
               Copy.render_message(body, %{date: @thursday_25_sep_2025}, false)
    end
  end

  describe "render_holiday_message/2" do
    test "renders the fixed holiday copy with the mention always on" do
      assert {:ok, rendered} =
               Copy.render_holiday_message(
                 "Tomorrow is {{holidayName}} ({{date}}), no training.",
                 %{date: ~D[2026-10-26], holiday_name: "October Holiday"}
               )

      assert rendered ==
               "@everyone\nTomorrow is October Holiday (Monday 26 October), no training."
    end

    test "rejects announcement tokens in holiday copy" do
      assert {:error, errors} =
               Copy.render_holiday_message("{{title}} is cancelled", %{
                 date: ~D[2026-10-26],
                 holiday_name: "October Holiday"
               })

      assert Enum.any?(errors, &(&1 =~ "title"))
    end
  end
end
