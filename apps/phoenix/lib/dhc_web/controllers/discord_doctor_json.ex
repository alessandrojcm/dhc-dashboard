defmodule DhcWeb.DiscordDoctorJSON do
  @moduledoc false

  def render("report.json", %{report: report}) do
    %{
      data: %{
        serverMembers: %{
          linkedActive: Enum.map(report.server_members.linked_active, &server_member/1),
          linkedInactive: Enum.map(report.server_members.linked_inactive, &server_member/1),
          pendingLink: Enum.map(report.server_members.pending_link, &server_member/1),
          unrecognized: Enum.map(report.server_members.unrecognized, &server_member/1)
        },
        missingMembers: Enum.map(report.missing_members, &missing_member/1),
        cache: %{
          fetchedAt: report.cache.fetched_at,
          ttlSeconds: report.cache.ttl_seconds
        }
      }
    }
  end

  defp server_member(row) do
    %{
      discordUserId: row.discord_user_id,
      username: row.username,
      displayName: row.display_name,
      avatar: row.avatar,
      joinedAt: row.joined_at,
      member: member(row.member),
      membershipStatus: row.membership_status,
      protected: row.protected,
      kickable: row.kickable
    }
  end

  defp missing_member(row) do
    %{
      member: member(row.member),
      membershipStatus: row.membership_status,
      linkStatus: row.link_status,
      discordUserId: row.discord_user_id,
      autoJoinPending: row.auto_join_pending
    }
  end

  defp member(nil), do: nil

  defp member(member) do
    %{id: member.id, firstName: member.first_name, lastName: member.last_name}
  end
end
