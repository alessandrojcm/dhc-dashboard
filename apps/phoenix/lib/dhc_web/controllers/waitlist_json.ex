defmodule DhcWeb.WaitlistJSON do
  @moduledoc false

  def render("status.json", %{status: status}) do
    %{data: %{isOpen: status.is_open}}
  end

  def render("analytics.json", %{analytics: analytics}) do
    %{
      data: %{
        totalCount: analytics.total_count,
        averageAge: analytics.average_age,
        genderDistribution: analytics.gender_distribution,
        ageDistribution: analytics.age_distribution
      }
    }
  end
end
