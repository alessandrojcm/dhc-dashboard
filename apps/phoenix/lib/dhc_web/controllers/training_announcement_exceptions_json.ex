defmodule DhcWeb.TrainingAnnouncementExceptionsJSON do
  @moduledoc "Exception slice renderer delegates to the shared Training Announcement DTOs."
  defdelegate suppressions(assigns), to: DhcWeb.TrainingAnnouncementsJSON
  defdelegate overrides(assigns), to: DhcWeb.TrainingAnnouncementsJSON
  defdelegate suppression(assigns), to: DhcWeb.TrainingAnnouncementsJSON
  defdelegate override(assigns), to: DhcWeb.TrainingAnnouncementsJSON
end
