defmodule DhcWeb.MembersJSON do
  @moduledoc false

  def render("insurance_form.json", %{insurance_form: insurance_form}) do
    %{data: %{link: insurance_form.link}}
  end

  def render("analytics.json", %{analytics: analytics}) do
    %{
      data: %{
        totalCount: analytics.total_count,
        averageAge: analytics.average_age,
        genderDistribution: analytics.gender_distribution,
        ageDistribution: analytics.age_distribution,
        weaponDistribution: analytics.weapon_distribution
      }
    }
  end
end
