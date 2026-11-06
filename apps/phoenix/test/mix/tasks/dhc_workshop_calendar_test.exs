defmodule Mix.Tasks.DhcWorkshopCalendarTest do
  use Dhc.DataCase, async: false

  alias Dhc.WorkshopCalendar

  setup do
    previous_config = WorkshopCalendar.config()
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    Application.put_env(:dhc, WorkshopCalendar,
      environment: "isolated",
      committee_calendar_id: "task-committee@test.invalid",
      participant_calendar_id: "task-participants@test.invalid",
      client_id: "task-client",
      client_secret: "task-secret",
      refresh_token: "task-refresh",
      req_options: [plug: {Req.Test, Dhc.WorkshopCalendar.Google}]
    )

    on_exit(fn ->
      Application.put_env(:dhc, WorkshopCalendar, previous_config)
      Mix.shell(previous_shell)
    end)
  end

  test "preview prints the authorized private JSON artifact and rejects arguments" do
    Mix.Tasks.Dhc.WorkshopCalendar.Preview.run([])
    assert_received {:mix_shell, :info, [output]}
    assert %{"environment" => "isolated", "workshops" => []} = Jason.decode!(output)

    assert_raise Mix.Error, ~r/usage: mix dhc.workshop_calendar.preview/, fn ->
      Mix.Tasks.Dhc.WorkshopCalendar.Preview.run(["no"])
    end
  end

  test "cold preview starts only a temporary Repo and performs no Calendar or job work" do
    repo_config = Application.fetch_env!(:dhc, Dhc.Repo)

    script = """
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)
    config =
      Application.fetch_env!(:dhc, Dhc.Repo)
      |> Keyword.merge(hostname: System.fetch_env!(\"DHC_COLD_PREVIEW_DB_HOST\"), port: String.to_integer(System.fetch_env!(\"DHC_COLD_PREVIEW_DB_PORT\")))
      |> Keyword.delete(:pool)
    Application.put_env(:dhc, Dhc.Repo, config)
    {:ok, before_repo} = Dhc.Repo.start_link(config)
    before = Dhc.Repo.query!(\"SELECT count(*) FROM oban_jobs\").rows
    :ok = GenServer.stop(before_repo)
    Mix.Task.clear()
    Mix.Task.run("dhc.workshop_calendar.preview")
    if Enum.any?(Application.started_applications(), &(elem(&1, 0) in [:dhc, :oban])) do
      raise "preview started Dhc or Oban"
    end

    if Process.whereis(Dhc.Repo), do: raise("preview left its temporary Repo running")
    {:ok, after_repo} = Dhc.Repo.start_link(config)
    after_count = Dhc.Repo.query!(\"SELECT count(*) FROM oban_jobs\").rows
    :ok = GenServer.stop(after_repo)
    if before != after_count, do: System.halt(1)
    """

    {output, 0} =
      System.cmd("mise", ["exec", "--", "mix", "run", "--no-start", "-e", script],
        cd: File.cwd!(),
        env: [
          {"MIX_ENV", "test"},
          {"DHC_COLD_PREVIEW_DB_HOST", Keyword.fetch!(repo_config, :hostname)},
          {"DHC_COLD_PREVIEW_DB_PORT", to_string(Keyword.fetch!(repo_config, :port))}
        ],
        stderr_to_stdout: true
      )

    assert output =~ ~s("workshops": [])
  end

  test "activate only accepts an explicit valid target" do
    assert_raise Mix.Error,
                 ~r/usage: mix dhc.workshop_calendar.activate isolated\|production/,
                 fn ->
                   Mix.Tasks.Dhc.WorkshopCalendar.Activate.run([])
                 end

    assert_raise Mix.Error,
                 ~r/usage: mix dhc.workshop_calendar.activate isolated\|production/,
                 fn ->
                   Mix.Tasks.Dhc.WorkshopCalendar.Activate.run(["development"])
                 end
  end

  test "activation command enables its configured target and refuses another target" do
    refute WorkshopCalendar.outbound?()

    assert_raise Mix.Error, ~r/Calendar activation refused: :environment_mismatch/, fn ->
      Mix.Tasks.Dhc.WorkshopCalendar.Activate.run(["production"])
    end

    refute WorkshopCalendar.outbound?()
    Mix.Tasks.Dhc.WorkshopCalendar.Activate.run(["isolated"])

    assert_received {:mix_shell, :info,
                     ["Calendar sending activated for isolated; 0 upcoming sources queued."]}

    assert WorkshopCalendar.outbound?()
  end
end
