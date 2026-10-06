defmodule DhcWeb.MemberAnnouncementsHTTP do
  @moduledoc """
  The problem fallback for the Member Announcements HTTP slice (ADR 0028).
  Subject/body validation failures are changesets (422 with `fields`).
  """

  use DhcWeb.Problem,
    reasons: %{
      no_recipients: {422, "No members match the chosen audience"}
    }
end
