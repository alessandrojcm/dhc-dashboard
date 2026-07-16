defmodule Dhc.Inventory.Stats do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Inventory.Container
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Repo

  @spec get_stats() :: %{
          categories: non_neg_integer(),
          containers: non_neg_integer(),
          items: non_neg_integer(),
          maintenance: non_neg_integer()
        }
  def get_stats do
    item_counts =
      from(i in Item,
        select: %{
          items: count(i.id),
          maintenance: filter(count(i.id), i.out_for_maintenance == true)
        }
      )
      |> Repo.one!()

    %{
      categories: Repo.aggregate(EquipmentCategory, :count),
      containers: Repo.aggregate(Container, :count),
      items: item_counts.items,
      maintenance: item_counts.maintenance
    }
  end
end
