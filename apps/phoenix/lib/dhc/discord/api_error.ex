defmodule Dhc.Discord.ApiError do
  @moduledoc "An error returned by Discord's REST API."

  @enforce_keys [:status]
  defstruct [:status, :code, :message, :details]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          code: integer() | nil,
          message: String.t() | nil,
          details: term()
        }
end
