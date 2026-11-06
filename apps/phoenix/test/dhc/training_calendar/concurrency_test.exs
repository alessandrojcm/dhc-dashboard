defmodule Dhc.TrainingCalendar.ConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.MemberFixtures
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.TrainingCalendar
  alias Dhc.TrainingCalendar.Google
  alias Dhc.TrainingCalendar.Grant
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  test "concurrent passes on separate connections cannot both observe and grant" do
    original = Application.fetch_env!(:dhc, TrainingCalendar)
    calendar = "training-#{Ecto.UUID.generate()}"
    email = "member-#{Ecto.UUID.generate()}@example.com"
    member = Sandbox.unboxed_run(Repo, fn -> MemberFixtures.member_fixture(email: email) end)

    Application.put_env(:dhc, TrainingCalendar,
      enabled: true,
      calendar_id: calendar,
      client_id: "client",
      client_secret: "secret",
      refresh_token: "refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn ->
      Application.put_env(:dhc, TrainingCalendar, original)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from g in Grant, where: g.calendar_id == ^calendar)
        Repo.delete_all(from m in MemberProfile, where: m.id == ^member.principal_id)
        Repo.delete_all(from p in UserProfile, where: p.id == ^member.profile_id)
        Repo.delete_all(from p in Principal, where: p.id == ^member.principal_id)
      end)
    end)

    test = self()

    Req.Test.stub(Google, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "access"})

        {"GET", _path} ->
          send(test, {:observing, self()})

          receive do
            :release -> Req.Test.json(conn, %{"kind" => "calendar#acl", "items" => []})
          after
            5_000 -> flunk("test did not release the observing pass")
          end

        {"POST", _path} ->
          assert conn.body_params["scope"]["value"] == email
          send(test, :granted)

          Req.Test.json(conn, %{
            "id" => "user:#{email}",
            "etag" => "one",
            "role" => "reader",
            "scope" => %{"type" => "user", "value" => email}
          })
      end
    end)

    first = Task.async(fn -> Sandbox.unboxed_run(Repo, &TrainingCalendar.sync/0) end)
    assert_receive {:observing, owner}, 5_000
    second = Task.async(fn -> Sandbox.unboxed_run(Repo, &TrainingCalendar.sync/0) end)
    assert {:ok, :busy} = Task.await(second)
    send(owner, :release)
    assert {:ok, %{added: 1}} = Task.await(first)
    assert_received :granted
    refute_received :granted
  end
end
