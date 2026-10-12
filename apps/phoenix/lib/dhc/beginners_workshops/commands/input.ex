defmodule Dhc.BeginnersWorkshops.Commands.Input do
  @moduledoc """
  How a Beginners' Workshop command reads the ids and attributes it was
  given, before any lock: a malformed workshop or Intake id is `:not_found`,
  a malformed person id `:person_not_found`, and an attribute may arrive with
  an atom or a string key.

  Every family module imports these (ALE-405); its own input casting
  (schedule attributes, Staff ids, notes, refund ids) stays in the family.
  Reach lets only `Commands` and `Commands.*` call this module.
  """

  @doc false
  @spec cast_id(term()) :: {:ok, binary()} | {:error, :not_found}
  def cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  @doc false
  @spec cast_person_id(term()) :: {:ok, binary()} | {:error, :person_not_found}
  def cast_person_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :person_not_found}
    end
  end

  @doc false
  @spec fetch_attr(map(), atom()) :: term()
  def fetch_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
