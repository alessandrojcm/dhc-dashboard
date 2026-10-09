defmodule DhcWeb.BeginnersWorkshopReportControllerTest do
  @moduledoc """
  ALE-397 contract test for the `beginnersWorkshopReport` slice: the
  `beginners.workshops.manage` gate and the report's shape, every object
  carrying exactly its schema's required keys. The figures themselves are
  `Dhc.BeginnersWorkshops.ReportTest`'s.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.Auth.UserRole
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator president coach member)
  @path "/api/beginners-workshops/report"

  setup do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture()

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    coordinator = role_subs["beginners_coordinator"]
    {workshop, [{intake, _token} | _]} = contacted_fixture(coordinator, 2)
    force_intake_state!(intake.id, "paid")
    force_intake_state!(intake.id, "attended")
    force_status!(workshop.id, "finalised")

    %{workshop: workshop}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp schemas do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    spec["components"]["schemas"]
  end

  defp keys(schema), do: Enum.sort(schemas()[schema]["required"])

  defp assert_keys(map, schema), do: assert(map |> Map.keys() |> Enum.sort() == keys(schema))

  test "only beginners.workshops.manage holders read the report", %{conn: conn} do
    assert conn |> get(@path) |> json_response(401)

    for role <- ~w(coach member),
        do: assert(conn |> as_role(role) |> get(@path) |> json_response(403))

    for role <- ~w(beginners_coordinator president),
        do: assert(%{"data" => %{}} = conn |> as_role(role) |> get(@path) |> json_response(200))
  end

  test "renders the report in the contract's shape", %{conn: conn} = ctx do
    assert %{"data" => data} =
             conn |> as_role("beginners_coordinator") |> get(@path) |> json_response(200)

    assert_keys(data, "BeginnersWorkshopReport")
    assert_keys(data["queue"], "BeginnersWorkshopReportQueue")
    assert_keys(data["queue"]["carriedFees"], "BeginnersWorkshopReportCarriedFees")
    assert_keys(data["twelveMonths"], "BeginnersWorkshopReportTwelveMonths")

    assert [row] = data["outcomes"]
    assert_keys(row, "BeginnersWorkshopReportOutcome")

    for {field, schema} <- [
          {"contacted", "Contacted"},
          {"exitsBeforePaying", "ExitsBeforePaying"},
          {"paid", "Paid"},
          {"exitsAfterPaying", "ExitsAfterPaying"},
          {"attendance", "Attendance"},
          {"afterAttending", "AfterAttending"}
        ],
        do: assert_keys(row[field], "BeginnersWorkshopReport" <> schema)

    assert [group] = row["groups"]
    assert_keys(group, "BeginnersWorkshopReportGroup")

    assert %{
             "workshopId" => workshop_id,
             "date" => "2026-11-14",
             "status" => "finalised",
             "batchesSent" => 1,
             "contacted" => %{"total" => 2, "batch" => 2, "fastTrack" => 0},
             "attendance" => %{"seated" => 1, "attended" => 1, "noShow" => 0, "rate" => 1.0},
             "exitsBeforePaying" => %{"total" => 0, "rate" => +0.0},
             "conversionRate" => +0.0
           } = row

    assert workshop_id == ctx.workshop.id
    assert %{"kind" => "batch", "number" => 1, "contacted" => 2, "paidInWindow" => 1} = group
  end
end
