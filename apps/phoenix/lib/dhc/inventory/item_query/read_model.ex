defmodule Dhc.Inventory.ItemQuery.ReadModel do
  @moduledoc """
  What one Item list read supplies to `Dhc.Inventory.ItemQuery.list/2`.

  Every field is required, so a read model cannot silently fall back to a
  shared default for its scope, search, or projection:

    * `:param` — its one extra parameter (`archived`, `availability`) as
      `{option_key, request_keys, parser}`. The option key is also its
      cursor-context key; atom values are bound into the cursor as strings.
    * `:scope` — constrains the `:item`-bound root query from the parsed
      options (archive, availability).
    * `:search` — applies a non-blank `q`.
    * `:project` — turns the visible `Item` rows into response rows.

  The functions are captures of the read model's own private functions, so
  its scope, search, and projection stay private to it; `ItemQuery` only
  calls them.
  """

  alias Dhc.Inventory.Item

  @enforce_keys [:param, :scope, :search, :project]
  defstruct @enforce_keys

  @typedoc "The read models' own extra-parameter reasons."
  @type param_error :: :invalid_archived | :invalid_availability

  @type param ::
          {atom(), [String.t()], (term() -> {:ok, term()} | {:error, param_error()})}

  @type t :: %__MODULE__{
          param: param(),
          scope: (Ecto.Query.t(), map() -> Ecto.Query.t()),
          search: (Ecto.Query.t(), String.t() -> Ecto.Query.t()),
          project: ([Item.t()] -> [term()])
        }
end
