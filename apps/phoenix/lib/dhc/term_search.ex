defmodule Dhc.TermSearch do
  @moduledoc """
  Staff-facing list search over names and emails.

  Staff type fragments ("ale", "ada love", "@gmail"), so a query is split on
  whitespace and every term must appear, case-insensitively, somewhere in the
  row. Postgres full-text search matched whole stemmed words only, which missed
  partial names and treated an email as a single token.

      require Dhc.TermSearch

      where(
        query,
        ^Dhc.TermSearch.every_term(q, fn term ->
          dynamic([p], Dhc.TermSearch.contains(p.first_name, ^term) or
            Dhc.TermSearch.contains(p.last_name, ^term))
        end)
      )
  """

  import Ecto.Query

  @doc "True when `field` contains `term`, ignoring case. A NULL field never matches."
  defmacro contains(field, term) do
    quote do
      fragment("strpos(lower(?), lower(?)) > 0", unquote(field), unquote(term))
    end
  end

  @doc """
  A dynamic that holds when every whitespace-separated term of `q` satisfies
  `match`, a function from a term to a dynamic. A blank `q` matches every row.
  """
  @spec every_term(String.t(), (String.t() -> Ecto.Query.dynamic_expr())) ::
          Ecto.Query.dynamic_expr()
  def every_term(q, match) when is_binary(q) and is_function(match, 1) do
    q
    |> String.split()
    |> Enum.reduce(dynamic(true), fn term, acc -> dynamic(^acc and ^match.(term)) end)
  end
end
