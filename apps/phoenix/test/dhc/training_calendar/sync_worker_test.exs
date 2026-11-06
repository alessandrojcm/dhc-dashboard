defmodule Dhc.TrainingCalendar.SyncWorkerTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.TrainingCalendar
  alias Dhc.TrainingCalendar.Google
  alias Dhc.TrainingCalendar.Workers.SyncWorker

  setup do
    original = Application.fetch_env!(:dhc, TrainingCalendar)

    Application.put_env(:dhc, TrainingCalendar,
      enabled: true,
      calendar_id: "training@example.com",
      client_id: "client",
      client_secret: "secret",
      refresh_token: "refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, TrainingCalendar, original) end)
    test = self()

    Req.Test.stub(Google, fn conn ->
      if conn.request_path == "/token" do
        Req.Test.json(conn, %{"access_token" => "access"})
      else
        assert conn.method == "GET"
        send(test, :sync_read)
        Req.Test.json(conn, %{"kind" => "calendar#acl", "items" => []})
      end
    end)

    :ok
  end

  test "midnight ticks act in winter, summer, and on either side of the DST changes" do
    for at <- [
          ~U[2026-01-10 00:00:00Z],
          ~U[2026-07-09 23:00:00Z],
          ~U[2026-03-29 00:00:00Z],
          ~U[2026-03-29 23:00:00Z],
          ~U[2026-10-24 23:00:00Z],
          ~U[2026-10-26 00:00:00Z]
        ] do
      assert :ok = SyncWorker.perform(cron_job(at))
      assert_received :sync_read
    end
  end

  test "the alternate UTC slot is a no-op rather than a second daily sync" do
    for at <- [
          ~U[2026-01-09 23:00:00Z],
          ~U[2026-07-10 00:00:00Z],
          ~U[2026-03-30 00:00:00Z],
          ~U[2026-10-25 23:00:00Z]
        ] do
      assert :ok = SyncWorker.perform(cron_job(at))
    end

    refute_received :sync_read
  end

  test "a queued midnight pass still acts after queue delay and a retry acts outside midnight" do
    assert :ok = SyncWorker.perform(cron_job(~U[2020-01-01 00:00:00Z]))
    assert_received :sync_read

    job = %{cron_job(~U[2026-07-10 02:30:00Z]) | attempt: 2}
    assert :ok = SyncWorker.perform(job)
    assert_received :sync_read
  end

  test "manual jobs use the same reconciliation without a cron time gate" do
    assert :ok = perform_job(SyncWorker, %{})
    assert_received :sync_read
  end

  test "errors remain safe Oban failures for bounded retry and existing Sentry reporting" do
    Req.Test.stub(Google, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "PRIVATE"})
    end)

    assert {:error, :unauthorized} = SyncWorker.perform(%Oban.Job{args: %{}})
  end

  test "pending ticks are unique and job arguments contain no roster or credentials" do
    first = SyncWorker.new(%{}) |> Oban.insert!()
    second = SyncWorker.new(%{}) |> Oban.insert!()
    assert second.conflict?
    assert first.id == second.id
    assert first.args == %{}
    assert first.max_attempts == 3
  end

  test "cron includes both UTC slots without changing other jobs' timezone" do
    config = Config.Reader.read!("config/config.exs", env: :dev, target: :host)
    plugins = config[:dhc][Oban][:plugins]
    cron = Keyword.fetch!(plugins, Oban.Plugins.Cron)

    assert {"0 0,23 * * *", SyncWorker} in cron[:crontab]
    assert Keyword.get(cron, :timezone, "Etc/UTC") == "Etc/UTC"
    assert {"0 0 * * *", Dhc.StripeSync.Worker} in cron[:crontab]
  end

  test "a backlogged alternate tick cannot suppress the real midnight job an hour later" do
    first = SyncWorker.new(%{}) |> Oban.insert!()
    old = DateTime.add(DateTime.utc_now(), -3_600)
    Dhc.Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [inserted_at: old])

    midnight = SyncWorker.new(%{}) |> Oban.insert!()
    refute midnight.conflict?
    assert midnight.id != first.id
  end

  defp cron_job(at),
    do: %Oban.Job{args: %{}, meta: %{"cron" => true}, attempt: 1, scheduled_at: at}
end
