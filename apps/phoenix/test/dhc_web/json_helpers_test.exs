defmodule DhcWeb.JSONHelpersTest do
  use ExUnit.Case, async: true

  alias DhcWeb.JSONHelpers

  describe "serialize_datetime/1" do
    test "returns nil for nil" do
      assert JSONHelpers.serialize_datetime(nil) == nil
    end

    test "truncates DateTime to seconds and emits ISO-8601" do
      dt = %DateTime{
        year: 2026,
        month: 9,
        day: 18,
        hour: 12,
        minute: 34,
        second: 56,
        microsecond: {123_456, 6},
        utc_offset: 0,
        std_offset: 0,
        zone_abbr: "UTC",
        time_zone: "Etc/UTC"
      }

      assert JSONHelpers.serialize_datetime(dt) == "2026-09-18T12:34:56Z"
    end

    test "truncates NaiveDateTime to seconds and emits ISO-8601" do
      dt = ~N[2026-09-18 12:34:56.123456]

      assert JSONHelpers.serialize_datetime(dt) == "2026-09-18T12:34:56"
    end
  end
end
