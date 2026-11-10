defmodule Mix.Tasks.DhcDestinationBackfillTest do
  use Dhc.DataCase, async: false

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.BeginnersWorkshops.BeginnersWorkshop
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops.Workshop
  alias Mix.Tasks.Dhc.DestinationBackfill.{Apply, Preview}

  @mapping %{
    "mappings" => [
      %{
        "venue" => "Club hall",
        "destination" => %{
          "destination_name" => "National Basketball Arena",
          "destination_address" => "Tymon Park, Dublin 6w"
        }
      }
    ]
  }

  setup do
    previous_config = WorkshopCalendar.config()
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Req.Test.stub(Google, fn _conn -> flunk("the backfill must never call Google") end)

    Application.put_env(
      :dhc,
      WorkshopCalendar,
      Keyword.merge(previous_config, active: false, req_options: [plug: {Req.Test, Google}])
    )

    on_exit(fn ->
      Application.put_env(:dhc, WorkshopCalendar, previous_config)
      Mix.shell(previous_shell)
    end)
  end

  @tag :tmp_dir
  test "preview prints the JSON artifact and refuses bad input", %{tmp_dir: dir} do
    workshop = WorkshopFixtures.workshop_fixture(location: "Club hall", status: "published")
    path = write!(dir, "mapping.json", @mapping)

    Preview.run([path])
    assert_received {:mix_shell, :info, [output]}

    assert %{"workshops" => rows, "proposed_targets" => [target]} = Jason.decode!(output)
    assert Enum.any?(rows, &(&1["source_id"] == workshop.id and &1["outcome"] == "change"))
    assert target["source_id"] == workshop.id
    assert %{destination_name: nil} = Repo.get!(Workshop, workshop.id)

    assert_raise Mix.Error, ~r/usage: mix dhc.destination_backfill.preview/, fn ->
      Preview.run([])
    end

    bad = write!(dir, "bad.json", %{"mappings" => [%{"venue" => "x"}]})
    assert_raise Mix.Error, ~r/Mapping refused/, fn -> Preview.run([bad]) end

    File.write!(Path.join(dir, "broken.json"), "{")

    assert_raise Mix.Error, ~r/is not JSON/, fn ->
      Preview.run([Path.join(dir, "broken.json")])
    end
  end

  @tag :tmp_dir
  test "cold preview starts only a temporary Repo and inserts no jobs", %{tmp_dir: dir} do
    repo_config = Application.fetch_env!(:dhc, Dhc.Repo)
    path = write!(dir, "mapping.json", @mapping)

    script = """
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)
    config =
      Application.fetch_env!(:dhc, Dhc.Repo)
      |> Keyword.merge(hostname: System.fetch_env!(\"DHC_COLD_PREVIEW_DB_HOST\"), port: String.to_integer(System.fetch_env!(\"DHC_COLD_PREVIEW_DB_PORT\")))
      |> Keyword.delete(:pool)
    Application.put_env(:dhc, Dhc.Repo, config)
    count = fn ->
      {:ok, repo} = Dhc.Repo.start_link(config)
      rows = Dhc.Repo.query!(\"SELECT (SELECT count(*) FROM oban_jobs), (SELECT count(*) FROM workshop_calendar_events), (SELECT max(updated_at) FROM club_activities), (SELECT max(updated_at) FROM beginners_workshops)\").rows
      :ok = GenServer.stop(repo)
      rows
    end
    before = count.()
    Mix.Task.clear()
    Mix.Task.run("dhc.destination_backfill.preview", [System.fetch_env!(\"DHC_BACKFILL_MAPPING\")])
    if Enum.any?(Application.started_applications(), &(elem(&1, 0) in [:dhc, :oban])) do
      raise "preview started Dhc or Oban"
    end

    if Process.whereis(Dhc.Repo), do: raise("preview left its temporary Repo running")
    if before != count.(), do: System.halt(1)
    """

    {output, 0} =
      System.cmd("mise", ["exec", "--", "mix", "run", "--no-start", "-e", script],
        cd: File.cwd!(),
        env: [
          {"MIX_ENV", "test"},
          {"DHC_COLD_PREVIEW_DB_HOST", Keyword.fetch!(repo_config, :hostname)},
          {"DHC_COLD_PREVIEW_DB_PORT", to_string(Keyword.fetch!(repo_config, :port))},
          {"DHC_BACKFILL_MAPPING", path}
        ],
        stderr_to_stdout: true
      )

    assert output =~ ~s("proposed_targets")
  end

  @tag :tmp_dir
  test "apply requires a plan and an operator, then prints per-target outcomes",
       %{tmp_dir: dir} do
    usage = ~r/usage: mix dhc.destination_backfill.apply PLAN.json --operator PRINCIPAL_ID/
    assert_raise Mix.Error, usage, fn -> Apply.run([]) end
    assert_raise Mix.Error, usage, fn -> Apply.run(["plan.json"]) end
    assert_raise Mix.Error, usage, fn -> Apply.run(["plan.json", "--operator"]) end

    workshop = WorkshopFixtures.workshop_fixture(location: "Club hall", status: "published")
    staff = staff!()

    beginners =
      BeginnersWorkshopFixtures.scheduled_fixture(staff, %{
        "date" => "2027-03-28",
        "venue" => "Club hall"
      })

    Preview.run([write!(dir, "mapping.json", @mapping)])
    assert_received {:mix_shell, :info, [output]}
    preview = Jason.decode!(output)

    plan =
      write!(dir, "plan.json", %{
        "mapping" => preview["mapping"],
        "approved_targets" => preview["proposed_targets"]
      })

    Apply.run([plan, "--operator", staff])
    assert_received {:mix_shell, :info, [result]}

    assert %{"results" => results} = Jason.decode!(result)

    assert Enum.sort(Enum.map(results, &{&1["source_kind"], &1["source_id"], &1["outcome"]})) ==
             Enum.sort([
               {"workshop", workshop.id, "changed"},
               {"beginners_workshop", beginners.id, "changed"}
             ])

    assert %{destination_name: "National Basketball Arena"} = Repo.get!(Workshop, workshop.id)

    assert %{destination_name: "National Basketball Arena"} =
             Repo.get!(BeginnersWorkshop, beginners.id)

    unknown = write!(dir, "unknown.json", %{"approved_targets" => []})
    assert_raise Mix.Error, ~r/Plan refused/, fn -> Apply.run([unknown, "--operator", staff]) end
  end

  defp write!(dir, name, document) do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(document))
    path
  end

  defp staff! do
    member = WorkshopFixtures.member_fixture()

    for role <- ["member", "workshop_coordinator", "beginners_coordinator"],
        do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

    member.principal_id
  end
end
