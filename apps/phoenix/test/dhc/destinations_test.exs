defmodule Dhc.DestinationsTest do
  @moduledoc """
  ALE-440: the domain-neutral destination rules shared by workshop-owning
  contexts — which manually supplied URLs are supported HTTPS Maps
  destinations, and how a destination composes the Calendar location string.
  """

  use ExUnit.Case, async: true

  alias Dhc.Destinations

  describe "validate_maps_url/1" do
    test "no link is always allowed" do
      assert :ok = Destinations.validate_maps_url(nil)
    end

    test "accepts Google Maps place, search, and coordinate URLs" do
      assert :ok =
               Destinations.validate_maps_url(
                 "https://www.google.com/maps/place/National+Basketball+Arena/@53.35,-6.25,17z"
               )

      assert :ok = Destinations.validate_maps_url("https://www.google.com/maps?q=Tallaght")
      assert :ok = Destinations.validate_maps_url("https://maps.google.com/?q=Clontarf")
      assert :ok = Destinations.validate_maps_url("https://google.com/maps/place/Some+Where")
    end

    test "accepts the Maps short-link hosts" do
      assert :ok = Destinations.validate_maps_url("https://maps.app.goo.gl/AbCdEf")
      assert :ok = Destinations.validate_maps_url("https://goo.gl/maps/AbCdEf")
      assert :ok = Destinations.validate_maps_url("https://g.co/maps/AbCdEf")
    end

    test "accepts uppercase scheme and host" do
      assert :ok = Destinations.validate_maps_url("HTTPS://WWW.GOOGLE.COM/maps?q=Tallaght")
    end

    test "rejects executable and non-secure schemes" do
      assert {:error, :unsupported_scheme} =
               Destinations.validate_maps_url("javascript:alert(1)")

      # Unparseable executable payloads are refused at the same seam.
      assert {:error, :invalid_url} = Destinations.validate_maps_url("data:text/html,<b>hi</b>")

      assert {:error, :unsupported_scheme} =
               Destinations.validate_maps_url("http://www.google.com/maps?q=Tallaght")

      assert {:error, :unsupported_scheme} = Destinations.validate_maps_url("//google.com/maps")
    end

    test "rejects embedded credentials" do
      assert {:error, :credentials} =
               Destinations.validate_maps_url("https://user:pass@www.google.com/maps?q=X")

      assert {:error, :credentials} =
               Destinations.validate_maps_url("https://staff@maps.app.goo.gl/AbCdEf")
    end

    test "rejects an explicit port" do
      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://www.google.com:8443/maps?q=Tallaght")
    end

    test "rejects supported hosts outside Maps paths" do
      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://www.google.com/search?q=maps")

      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://google.com/search?q=maps")

      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://goo.gl/AbCdEf")

      assert {:error, :unsupported_target} = Destinations.validate_maps_url("https://g.co/AbCdEf")

      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://www.google.com/mapsettings")
    end

    test "rejects unsupported hosts" do
      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://evil.example.com/maps?q=Tallaght")

      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://google.com.evil.example.com/maps")

      assert {:error, :unsupported_target} =
               Destinations.validate_maps_url("https://notgoogle.maps.example.com/place")
    end

    test "rejects unparseable input and over-long links" do
      assert {:error, :invalid_url} = Destinations.validate_maps_url("not a url")
      assert {:error, :invalid_url} = Destinations.validate_maps_url(42)
      # No scheme at all cannot be an https Maps destination.
      assert {:error, :unsupported_scheme} = Destinations.validate_maps_url("")
      # A hostless URL is not a Maps destination.
      assert match?(
               {:error, _},
               Destinations.validate_maps_url("https://")
             )

      assert {:error, :invalid_url} =
               Destinations.validate_maps_url("https://" <> String.duplicate("a", 2048))
    end

    test "every refusal has one user-facing message" do
      for reason <- [:invalid_url, :unsupported_scheme, :credentials, :unsupported_target] do
        assert is_binary(Destinations.url_error_message(reason))
      end
    end
  end

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

  describe "calendar_location/3" do
    test "composes name and address" do
      assert Destinations.calendar_location(
               "National Basketball Arena",
               "Tymon Park, Dublin 6w",
               "Main hall"
             ) == "National Basketball Arena, Tymon Park, Dublin 6w"
    end

    test "either half alone composes without a separator" do
      assert Destinations.calendar_location("Arena", nil, "Main hall") == "Arena"

      assert Destinations.calendar_location(nil, "Tymon Park, Dublin 6w", "Main hall") ==
               "Tymon Park, Dublin 6w"
    end

    test "falls back to the label for legacy and label-only rows" do
      assert Destinations.calendar_location(nil, nil, "Main hall") == "Main hall"
      assert Destinations.calendar_location("  ", "", "Main hall") == "Main hall"
    end

    test "a destination that is only a link keeps the readable label" do
      # A URL is not a location people can read; the Calendar location stays
      # recognizable and the link is used for directions, not for the event.
      assert Destinations.calendar_location(nil, nil, "Main hall") == "Main hall"
    end
  end

  describe "validate_changeset/1" do
    @types %{destination_name: :string, destination_address: :string, directions_url: :string}

    defp cast(data \\ %{}, attrs),
      do: Ecto.Changeset.cast({data, @types}, attrs, Map.keys(@types))

    test "blank text is absent and a supplied Maps link is judged with its one message" do
      changeset =
        cast(%{"destination_name" => "  ", "directions_url" => "http://maps.google.com/?q=x"})
        |> Destinations.validate_changeset()

      assert Ecto.Changeset.get_change(changeset, :destination_name) == nil
      assert changeset.errors[:directions_url] == {"Directions link must be an https link", []}
    end

    test "clearing a stored link is valid, and the lengths are the shared maxima" do
      assert %{valid?: true} =
               %{directions_url: "https://maps.app.goo.gl/AbCdEf"}
               |> cast(%{"directions_url" => nil})
               |> Destinations.validate_changeset()

      assert %{valid?: false, errors: errors} =
               cast(%{
                 "destination_name" => String.duplicate("n", Destinations.name_max() + 1),
                 "destination_address" => String.duplicate("a", Destinations.address_max() + 1)
               })
               |> Destinations.validate_changeset()

      assert Keyword.keys(errors) |> Enum.sort() == [:destination_address, :destination_name]
    end
  end
end
