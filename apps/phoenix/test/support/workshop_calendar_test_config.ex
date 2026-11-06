defmodule Dhc.WorkshopCalendarTestConfig do
  @moduledoc "Test-only inactive sending; production uses durable target-bound activation."

  alias Dhc.WorkshopCalendar

  def deactivate! do
    config = WorkshopCalendar.config()
    Application.put_env(:dhc, WorkshopCalendar, Keyword.put(config, :active, false))
    config
  end

  def activate!(config), do: Application.put_env(:dhc, WorkshopCalendar, config)
end
