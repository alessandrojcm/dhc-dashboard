defmodule Mix.Tasks.DhcGoogleCalendarCheckTest do
  use ExUnit.Case, async: false

  setup do
    Dhc.GoogleCalendarAuthConfig.configure!(__MODULE__)
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "prints only the safe report and exits unsuccessfully when credentials need repair" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "invalid_client", "error_description" => "PRIVATE"})
    end)

    assert_raise Mix.Error, ~r/Google Calendar check failed/, fn ->
      Mix.Tasks.Dhc.GoogleCalendar.Check.run([])
    end

    assert_received {:mix_shell, :info, [output]}
    assert Jason.decode!(output) == %{"authentication" => "invalid_client", "calendars" => %{}}
    refute output =~ "PRIVATE"
  end

  test "rejects arguments before performing any checks" do
    assert_raise Mix.Error, ~r/usage: mix dhc.google_calendar.check/, fn ->
      Mix.Tasks.Dhc.GoogleCalendar.Check.run(["production"])
    end
  end

  test "cold check never starts Dhc, Oban, or Repo" do
    script = """
    Mix.Task.clear()
    try do
      Mix.Task.run("dhc.google_calendar.check")
    rescue
      Mix.Error -> :ok
    end
    if Enum.any?(Application.started_applications(), &(elem(&1, 0) in [:dhc, :oban])) do
      raise "check started Dhc or Oban"
    end
    if Process.whereis(Dhc.Repo), do: raise("check started Repo")
    """

    {output, 0} =
      System.cmd("mise", ["exec", "--", "mix", "run", "--no-start", "-e", script],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output =~ ~s("authentication": "configuration")
  end
end
