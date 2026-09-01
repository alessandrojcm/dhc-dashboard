defmodule IdempotencyPlug.ErlangTerm do
  @moduledoc """
  Ecto type vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(term), do: {:ok, term}

  @impl true
  def load(binary) when is_binary(binary), do: {:ok, :erlang.binary_to_term(binary, [:safe])}

  @impl true
  def dump(term), do: {:ok, :erlang.term_to_binary(term)}
end
