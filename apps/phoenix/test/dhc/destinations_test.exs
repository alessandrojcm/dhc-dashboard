defmodule Dhc.DestinationsTest do
  @moduledoc """
  ALE-440/ALE-442: the domain-neutral destination rules shared by
  workshop-owning contexts — manual text or a selected place, never both —
  and how a destination composes the Calendar location string.
  """

  use ExUnit.Case, async: true

  alias Dhc.Destinations

  describe "normalize_optional/1" do
    test "absent stays absent and whitespace is absent" do
      assert Destinations.normalize_optional(nil) == nil
      assert Destinations.normalize_optional("") == nil
      assert Destinations.normalize_optional("   \n\t ") == nil
    end

    test "text is trimmed" do
      assert Destinations.normalize_optional("  National Basketball Arena ") ==
               "National Basketball Arena"
    end
  end

  describe "calendar_location/2" do
    test "the manual destination text is the location" do
      assert Destinations.calendar_location(
               " National Basketball Arena, Tymon Park, Dublin 6w ",
               "Main hall"
             ) == "National Basketball Arena, Tymon Park, Dublin 6w"
    end

    test "falls back to the label for legacy, label-only and selected-place rows" do
      assert Destinations.calendar_location(nil, "Main hall") == "Main hall"
      assert Destinations.calendar_location("  ", "Main hall") == "Main hall"
      assert Destinations.calendar_location(nil, nil) == ""
    end
  end

  describe "validate_changeset/1" do
    @types %{destination_text: :string}

    defp cast(data \\ %{}, attrs),
      do: Ecto.Changeset.cast({data, @types}, attrs, Map.keys(@types))

    test "blank text is absent and clearing stored text is valid" do
      assert Ecto.Changeset.get_change(
               cast(%{"destination_text" => "  "}) |> Destinations.validate_changeset(),
               :destination_text
             ) == nil

      assert %{valid?: true, changes: %{destination_text: nil}} =
               %{destination_text: "Arena"}
               |> cast(%{"destination_text" => nil})
               |> Destinations.validate_changeset()
    end

    test "text is trimmed and bounded by the shared maximum" do
      assert %{valid?: true, changes: %{destination_text: "Arena, Dublin"}} =
               cast(%{"destination_text" => " Arena, Dublin "})
               |> Destinations.validate_changeset()

      assert %{valid?: false, errors: [destination_text: _]} =
               cast(%{"destination_text" => String.duplicate("n", Destinations.text_max() + 1)})
               |> Destinations.validate_changeset()
    end
  end

  describe "validate_changeset/2 provenance (ALE-442)" do
    @place_types %{
      destination_text: :string,
      destination_provider: :string,
      destination_place_id: :string,
      destination_selected_at: :utc_datetime
    }

    @now ~U[2026-11-11 09:30:00.123456Z]

    # A selected place: Google's own name and address are never stored, and
    # a selected destination carries no manual text.
    @selected %{
      destination_text: nil,
      destination_provider: "google",
      destination_place_id: "place_hall",
      destination_selected_at: ~U[2025-01-01 00:00:00Z]
    }

    @manual %{
      destination_text: "Our hall, Dublin 8",
      destination_provider: nil,
      destination_place_id: nil,
      destination_selected_at: nil
    }

    defp place_changeset(data, attrs) do
      {data, @place_types}
      |> Ecto.Changeset.cast(attrs, Destinations.fields())
      |> Destinations.validate_changeset(now: @now)
    end

    test "a new Place ID records only the selection's identity and drops the manual text" do
      changeset =
        place_changeset(@manual, %{
          "destination_text" => "",
          "destination_place_id" => "place_hall"
        })

      assert changeset.valid?

      assert changeset.changes == %{
               destination_text: nil,
               destination_provider: "google",
               destination_place_id: "place_hall",
               destination_selected_at: ~U[2026-11-11 09:30:00Z]
             }

      # A caller that omits the text still never leaves both stored.
      assert place_changeset(@manual, %{"destination_place_id" => "place_hall"}).changes.destination_text ==
               nil
    end

    test "Destinations.fields/0 casts no provider text or credits" do
      assert Destinations.fields() == [:destination_text, :destination_place_id]
    end

    test "an unrelated resubmission preserves the selection and its timestamp" do
      changeset =
        place_changeset(@selected, %{
          "destination_text" => "",
          "destination_place_id" => "place_hall"
        })

      assert changeset.valid?
      assert changeset.changes == %{}

      assert place_changeset(@selected, %{}).changes == %{}
    end

    test "typed text without the place replaces the stored place" do
      changeset =
        place_changeset(@selected, %{
          "destination_text" => "Another venue",
          "destination_place_id" => ""
        })

      assert changeset.valid?

      assert changeset.changes == %{
               destination_text: "Another venue",
               destination_provider: nil,
               destination_place_id: nil,
               destination_selected_at: nil
             }

      # Omitting the place entirely is the same manual destination.
      assert %{valid?: true, changes: %{destination_place_id: nil}} =
               place_changeset(@selected, %{"destination_text" => "Another venue"})
    end

    test "text beside a Place ID is refused: a destination is a place or text, never both" do
      for {data, attrs} <- [
            {%{}, %{"destination_text" => "Hall", "destination_place_id" => "place_hall"}},
            {@selected, %{"destination_text" => "Hall", "destination_place_id" => "place_hall"}},
            {@selected, %{"destination_text" => "Hall", "destination_place_id" => "place_annex"}},
            # Stored text resubmitted unchanged beside a new place is still both.
            {@manual,
             %{
               "destination_text" => @manual.destination_text,
               "destination_place_id" => "place_hall"
             }}
          ] do
        assert %{valid?: false, errors: [destination_text: _]} = place_changeset(data, attrs)
      end
    end

    test "replacing the place stamps a new selection" do
      changeset = place_changeset(@selected, %{"destination_place_id" => "place_annex"})

      assert changeset.valid?

      assert changeset.changes == %{
               destination_place_id: "place_annex",
               destination_selected_at: ~U[2026-11-11 09:30:00Z]
             }
    end

    test "clearing the Place ID clears provider identity" do
      changeset = place_changeset(@selected, %{"destination_place_id" => ""})

      assert changeset.valid?

      assert changeset.changes == %{
               destination_provider: nil,
               destination_place_id: nil,
               destination_selected_at: nil
             }
    end

    test "a manual destination never gains a provider" do
      changeset = place_changeset(%{}, %{"destination_text" => "Manual hall"})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :destination_provider)
    end

    test "a malformed Place ID is refused" do
      assert %{errors: [destination_place_id: {"is not a valid place", []}]} =
               place_changeset(%{}, %{"destination_place_id" => "../places/x"})
    end
  end
end
