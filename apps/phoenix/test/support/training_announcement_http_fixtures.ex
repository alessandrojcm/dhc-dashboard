defmodule DhcWeb.TrainingAnnouncementHTTPFixtures do
  @moduledoc "Network-free committee fixtures for the Training Announcement contract tests."
  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  def install do
    roles = ~w(sparring_coordinator coach president admin committee_coordinator member)

    role_subs =
      Map.new(roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture()

        if role != "member",
          do: Repo.insert!(%Dhc.Auth.UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    today = ClubCalendar.today()

    for year <- today.year..(today.year + 1) do
      Repo.insert!(%Holiday{
        date: Date.new!(year, 1, 1),
        name: "New Year",
        source_id: "year-#{year}",
        fetched_at: DateTime.utc_now()
      })
    end

    OpenApiVerifier.install(roles: roles, role_subs: role_subs)
  end

  def as_role(conn, role \\ "coach"),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  def attrs do
    %{
      "kind" => "sparring",
      "oneOffDate" => Date.to_iso8601(Date.add(ClubCalendar.today(), 7)),
      "postTime" => "14:00:00",
      "title" => "Training {{date}}",
      "message" => "Come on {{weekday}}",
      "mentionEveryone" => false
    }
  end
end
