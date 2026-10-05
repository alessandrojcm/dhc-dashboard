defmodule Dhc.ClubCalendarTest do
  @moduledoc """
  ALE-318 (promotion: today/on_date/to_utc on the tz database) and ALE-319
  (Irish bank-holiday cache with OpenHolidays fetch-on-miss and the daily
  refresh seam).

  HTTP is stubbed with Bypass pointed at via `:openholidays_api_url`
  (Bypass prior art: the Discord worker tests — the ticket names the Web
  Push sender tests, which cover the same hop through a Req `plug:`
  instead). `async: false`: the tests repoint global application env per
  test.
  """

  use Dhc.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.ClubCalendar.OpenHolidays
  alias Dhc.Repo

  setup do
    original = Application.get_env(:dhc, :openholidays_api_url)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:dhc, :openholidays_api_url)
        url -> Application.put_env(:dhc, :openholidays_api_url, url)
      end
    end)

    :ok
  end

  describe "today/0, on_date/1 and to_utc/2" do
    test "zone is Europe/Dublin" do
      assert ClubCalendar.zone() == "Europe/Dublin"
    end

    test "today agrees with the Dublin civil date" do
      assert ClubCalendar.today() ==
               DateTime.now!("Europe/Dublin", Tz.TimeZoneDatabase) |> DateTime.to_date()
    end

    test "on_date converts a late-evening UTC timestamp to the next Dublin day in summer" do
      assert ClubCalendar.on_date(~U[2026-06-01 23:30:00Z]) == ~D[2026-06-02]
      assert ClubCalendar.on_date(~U[2026-01-01 23:30:00Z]) == ~D[2026-01-01]
    end

    test "to_utc applies the winter offset" do
      assert ClubCalendar.to_utc(~D[2026-01-15], ~T[19:00:00]) == ~U[2026-01-15 19:00:00Z]
    end

    test "to_utc applies the summer offset across the late-March transition" do
      # Clocks go forward on 2026-03-29 (01:00 GMT -> 02:00 IST).
      assert ClubCalendar.to_utc(~D[2026-03-28], ~T[19:00:00]) == ~U[2026-03-28 19:00:00Z]
      assert ClubCalendar.to_utc(~D[2026-03-29], ~T[19:00:00]) == ~U[2026-03-29 18:00:00Z]
    end

    test "to_utc applies the winter offset across the late-October transition" do
      # Clocks go back on 2026-10-25 (02:00 IST -> 01:00 GMT).
      assert ClubCalendar.to_utc(~D[2026-10-24], ~T[19:00:00]) == ~U[2026-10-24 18:00:00Z]
      assert ClubCalendar.to_utc(~D[2026-10-25], ~T[19:00:00]) == ~U[2026-10-25 19:00:00Z]
    end

    test "to_utc resolves a spring-forward gap to the post-gap instant" do
      # 01:30 never happens on 2026-03-29; the post-gap instant is 01:00Z.
      assert ClubCalendar.to_utc(~D[2026-03-29], ~T[01:30:00]) == ~U[2026-03-29 01:00:00Z]
    end

    test "to_utc resolves an autumn ambiguity to the first occurrence" do
      # 01:30 happens twice on 2026-10-25; the first is 01:30 IST (00:30Z).
      assert ClubCalendar.to_utc(~D[2026-10-25], ~T[01:30:00]) == ~U[2026-10-25 00:30:00Z]
    end
  end

  describe "holiday_on/1" do
    test "answers a cached holiday without touching the network" do
      insert_holiday!(~D[2026-10-26], "October Holiday", "source-1")

      assert {:ok, %Holiday{date: ~D[2026-10-26], name: "October Holiday"}} =
               ClubCalendar.holiday_on(~D[2026-10-26])
    end

    test "answers nil for a cached year with no holiday on that date" do
      insert_holiday!(~D[2026-10-26], "October Holiday", "source-1")

      assert {:ok, nil} = ClubCalendar.holiday_on(~D[2026-10-27])
    end

    test "fetches, stores, and answers a year never fetched" do
      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        assert conn.query_params["countryIsoCode"] == "IE"
        assert conn.query_params["languageIsoCode"] == "EN"
        assert conn.query_params["validFrom"] == "2027-01-01"
        assert conn.query_params["validTo"] == "2027-12-31"

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!([holiday_item(~D[2027-03-17], "Saint Patrick's Day")])
        )
      end)

      assert {:ok, %Holiday{date: ~D[2027-03-17], name: "Saint Patrick's Day"}} =
               ClubCalendar.holiday_on(~D[2027-03-17])

      assert {:ok, nil} = ClubCalendar.holiday_on(~D[2027-03-18])

      # The stored row answers the next call with no further HTTP.
      assert {:ok, %Holiday{name: "Saint Patrick's Day"}} =
               ClubCalendar.holiday_on(~D[2027-03-17])
    end

    test "expands a multi-day holiday into one row per date" do
      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        item =
          holiday_item(~D[2027-12-25], "Christmas", end_date: ~D[2027-12-26])

        Plug.Conn.send_resp(conn, 200, Jason.encode!([item]))
      end)

      assert {:ok, %Holiday{name: "Christmas"}} = ClubCalendar.holiday_on(~D[2027-12-25])
      assert {:ok, %Holiday{name: "Christmas"}} = ClubCalendar.holiday_on(~D[2027-12-26])
    end

    test "fails open on a source error and leaves cached rows untouched" do
      insert_holiday!(~D[2027-03-17], "Saint Patrick's Day", "source-1")

      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect(bypass, "GET", "/PublicHolidays", fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      log =
        capture_log(fn ->
          assert {:ok, nil} = ClubCalendar.holiday_on(~D[2028-06-01])
        end)

      assert log =~ "[club-calendar] OpenHolidays fetch failed"

      # The previously cached row survives the failed fetch.
      assert {:ok, %Holiday{name: "Saint Patrick's Day"}} =
               ClubCalendar.holiday_on(~D[2027-03-17])
    end

    test "fails open when the source is unreachable" do
      bypass = Bypass.open()
      point_at_bypass(bypass)
      Bypass.down(bypass)

      assert {:ok, nil} = ClubCalendar.holiday_on(~D[2029-05-01])
    end
  end

  describe "holidays_between/2" do
    test "returns every cached holiday in the inclusive range, ordered by date" do
      insert_holiday!(~D[2026-12-26], "St Stephen's Day", "source-2")
      insert_holiday!(~D[2026-12-25], "Christmas Day", "source-1")
      insert_holiday!(~D[2026-12-27], "Not in range", "source-3")

      assert {:ok, [%Holiday{date: ~D[2026-12-25]}, %Holiday{date: ~D[2026-12-26]}]} =
               ClubCalendar.holidays_between(~D[2026-12-25], ~D[2026-12-26])
    end

    test "accepts the range in either order" do
      insert_holiday!(~D[2026-12-25], "Christmas Day", "source-1")

      assert {:ok, [%Holiday{date: ~D[2026-12-25]}]} =
               ClubCalendar.holidays_between(~D[2026-12-26], ~D[2026-12-25])
    end

    test "fetches unfetched years in the window before answering" do
      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect(bypass, "GET", "/PublicHolidays", fn conn ->
        year = String.slice(conn.query_params["validFrom"], 0, 4)

        items =
          case year do
            "2030" -> [holiday_item(~D[2030-10-27], "October Holiday")]
            "2031" -> [holiday_item(~D[2031-10-26], "October Holiday")]
          end

        Plug.Conn.send_resp(conn, 200, Jason.encode!(items))
      end)

      assert {:ok, [%Holiday{date: ~D[2030-10-27]}, %Holiday{date: ~D[2031-10-26]}]} =
               ClubCalendar.holidays_between(~D[2030-06-01], ~D[2031-12-31])
    end
  end

  describe "OpenHolidays.fetch_year/1" do
    test "returns one row per date, date-ascending within multi-day holidays" do
      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!([
            holiday_item(~D[2027-12-25], "Christmas", end_date: ~D[2027-12-26]),
            holiday_item(~D[2027-03-17], "Saint Patrick's Day")
          ])
        )
      end)

      assert {:ok, [%{date: ~D[2027-12-25]}, %{date: ~D[2027-12-26]}, %{date: ~D[2027-03-17]}]} =
               OpenHolidays.fetch_year(2027)
    end

    test "rejects a non-list body" do
      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{holidays: []}))
      end)

      assert {:error, {:unexpected_shape, _}} = OpenHolidays.fetch_year(2027)
    end
  end

  describe "refresh_year/1" do
    test "upserts returned dates and deletes dates the source no longer returns" do
      insert_holiday!(~D[2032-01-01], "Old name", "old-source")
      insert_holiday!(~D[2032-06-01], "Stale entry", "stale-source")

      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!([holiday_item(~D[2032-01-01], "New Year's Day", id: "new-source")])
        )
      end)

      assert :ok = ClubCalendar.refresh_year(2032)

      assert {:ok, %Holiday{name: "New Year's Day", source_id: "new-source"}} =
               ClubCalendar.holiday_on(~D[2032-01-01])

      assert {:ok, nil} = ClubCalendar.holiday_on(~D[2032-06-01])
    end

    test "an empty source response keeps cached rows and reports an error" do
      insert_holiday!(~D[2033-01-01], "New Year's Day", "source-1")

      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        Plug.Conn.send_resp(conn, 200, Jason.encode!([]))
      end)

      assert {:error, :empty_response} = ClubCalendar.refresh_year(2033)

      assert {:ok, %Holiday{name: "New Year's Day"}} = ClubCalendar.holiday_on(~D[2033-01-01])
    end

    test "a source failure keeps cached rows and reports an error" do
      insert_holiday!(~D[2034-01-01], "New Year's Day", "source-1")

      bypass = Bypass.open()
      point_at_bypass(bypass)

      Bypass.expect_once(bypass, "GET", "/PublicHolidays", fn conn ->
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      log =
        capture_log(fn ->
          assert {:error, {:unexpected_status, 503, _}} = ClubCalendar.refresh_year(2034)
        end)

      assert log =~ "[club-calendar] OpenHolidays fetch failed"

      assert {:ok, %Holiday{name: "New Year's Day"}} = ClubCalendar.holiday_on(~D[2034-01-01])
    end
  end

  defp point_at_bypass(bypass) do
    Application.put_env(:dhc, :openholidays_api_url, "http://localhost:#{bypass.port}")
  end

  defp insert_holiday!(date, name, source_id) do
    %Holiday{}
    |> Holiday.changeset(%{
      date: date,
      name: name,
      source_id: source_id,
      fetched_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp holiday_item(date, name, opts \\ []) do
    end_date = Keyword.get(opts, :end_date, date)

    %{
      "id" => Keyword.get(opts, :id, Ecto.UUID.generate()),
      "startDate" => Date.to_iso8601(date),
      "endDate" => Date.to_iso8601(end_date),
      "nationwide" => true,
      "type" => "Public",
      "name" => [%{"language" => "EN", "text" => name}]
    }
  end
end
