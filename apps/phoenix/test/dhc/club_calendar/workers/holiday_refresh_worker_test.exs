defmodule Dhc.ClubCalendar.Workers.HolidayRefreshWorkerTest do
  @moduledoc """
  ALE-319: the daily holiday-cache refresh pass.

  The worker refreshes the current and next Dublin year and always
  succeeds: a failed year keeps its cached rows and is repaired by the
  The worker refreshes the current and next Dublin year and always
  succeeds: a failed year keeps its cached rows and is repaired by the
  next pass. HTTP is stubbed with Bypass (Bypass prior art: the Discord
  worker tests). `async: false`: the tests repoint global application env
  per test.
  """

  use Dhc.DataCase, async: false

  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.ClubCalendar.Workers.HolidayRefreshWorker
  alias Dhc.Repo

  import Ecto.Query

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

  test "refreshes the current and next year and succeeds" do
    bypass = Bypass.open()
    Application.put_env(:dhc, :openholidays_api_url, "http://localhost:#{bypass.port}")

    test_pid = self()
    this_year = ClubCalendar.today().year

    Bypass.expect(bypass, "GET", "/PublicHolidays", fn conn ->
      send(test_pid, {:fetched, conn.query_params["validFrom"]})

      year = conn.query_params["validFrom"] |> String.slice(0, 4) |> String.to_integer()

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!([holiday_item(Date.new!(year, 1, 1), "New Year's Day")])
      )
    end)

    assert :ok = HolidayRefreshWorker.perform(%Oban.Job{args: %{}})

    expected_this_year = "#{this_year}-01-01"
    expected_next_year = "#{this_year + 1}-01-01"
    assert_received {:fetched, ^expected_this_year}
    assert_received {:fetched, ^expected_next_year}

    assert Repo.exists?(
             from h in Holiday,
               where: h.date == ^Date.new!(this_year, 1, 1) and h.name == "New Year's Day"
           )

    assert Repo.exists?(
             from h in Holiday,
               where: h.date == ^Date.new!(this_year + 1, 1, 1) and h.name == "New Year's Day"
           )
  end

  test "a failed year does not block the other year and the job still succeeds" do
    bypass = Bypass.open()
    Application.put_env(:dhc, :openholidays_api_url, "http://localhost:#{bypass.port}")

    this_year = ClubCalendar.today().year

    Bypass.expect(bypass, "GET", "/PublicHolidays", fn conn ->
      if String.starts_with?(conn.query_params["validFrom"], "#{this_year}-") do
        Plug.Conn.send_resp(conn, 500, "boom")
      else
        year = conn.query_params["validFrom"] |> String.slice(0, 4) |> String.to_integer()

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!([holiday_item(Date.new!(year, 1, 1), "New Year's Day")])
        )
      end
    end)

    assert :ok = HolidayRefreshWorker.perform(%Oban.Job{args: %{}})

    assert Repo.exists?(
             from h in Holiday,
               where: h.date == ^Date.new!(this_year + 1, 1, 1)
           )
  end

  defp holiday_item(date, name) do
    %{
      "id" => Ecto.UUID.generate(),
      "startDate" => Date.to_iso8601(date),
      "endDate" => Date.to_iso8601(date),
      "nationwide" => true,
      "type" => "Public",
      "name" => [%{"language" => "EN", "text" => name}]
    }
  end
end
