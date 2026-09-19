defmodule Dhc.Inventory.LocksTest do
  @moduledoc """
  H11: `Repo.get/3` (and `get_by`/`one`/`all`) ignore a `:lock` option, so a
  locked read must live inside the query. This module guards that rule.
  """

  use ExUnit.Case, async: true

  alias Dhc.Inventory.Container
  alias Dhc.Inventory.Locks
  alias Dhc.Repo

  @repo_lock_funs [:get, :get_by, :one, :all]

  test "for_update_query emits FOR UPDATE" do
    {sql, _params} =
      Ecto.Adapters.SQL.to_sql(
        :all,
        Repo,
        Locks.for_update_query(Container, Ecto.UUID.generate())
      )

    assert sql =~ "FOR UPDATE"
  end

  test "detects lock as a Repo option, including multiline, and ignores comments and query locks" do
    source = """
    defmodule Sample do
      def mixed(id, query) do
        Repo.get(Schema, id, lock: "FOR UPDATE")
        Repo.get_by(Schema, [name: "x"], lock: "FOR SHARE")
        Repo.one(
          query,
          lock: "FOR UPDATE"
        )
        Repo.all(query, lock: "FOR UPDATE")
        Dhc.Repo.get(Schema, id, lock: "FOR UPDATE")

        # Repo.get(Schema, id, lock: "FOR UPDATE")
        Repo.one(from(x in Schema, where: x.id == ^id, lock: "FOR UPDATE"))
        from(x in Schema, lock: "FOR UPDATE") |> Repo.one()
      end
    end
    """

    assert repo_lock_option_hits("lib/sample.ex", source) == [
             {"lib/sample.ex", 3},
             {"lib/sample.ex", 4},
             {"lib/sample.ex", 5},
             {"lib/sample.ex", 9},
             {"lib/sample.ex", 10}
           ]
  end

  test "apps/phoenix/lib never passes lock: as a Repo option" do
    hits =
      Enum.flat_map(lib_sources(), fn path ->
        repo_lock_option_hits(relative_lib(path), File.read!(path))
      end)

    assert hits == [], """
    `lock:` is only valid inside the query (`from(..., lock:)` or `lock/2`).
    `Repo.get/3`, `Repo.get_by/3`, `Repo.one/2`, and `Repo.all/2` ignore
    unknown options, so a lock clause passed as a Repo option is an
    unlocked SELECT (H11). Use `Dhc.Inventory.Locks.get_for_update/2`.

    Hits:
    #{format_hits(hits)}
    """
  end

  defp lib_sources do
    __DIR__
    |> Path.join("../../../lib")
    |> Path.expand()
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/stripe/generated/"))
  end

  defp repo_lock_option_hits(path, source) do
    ast = Code.string_to_quoted!(source, file: path, columns: true)

    {_ast, hits} = Macro.prewalk(ast, [], &collect_repo_lock_option(&1, &2, path))
    Enum.reverse(hits)
  end

  defp collect_repo_lock_option({{:., _, [alias, fun]}, meta, args} = node, acc, path)
       when fun in @repo_lock_funs and is_list(args) do
    if repo_alias?(alias) and lock_option?(args) do
      {node, [{path, Keyword.get(meta, :line, 0)} | acc]}
    else
      {node, acc}
    end
  end

  defp collect_repo_lock_option(node, acc, _path), do: {node, acc}

  defp repo_alias?({:__aliases__, _, [:Repo]}), do: true
  defp repo_alias?({:__aliases__, _, [:Dhc, :Repo]}), do: true
  defp repo_alias?(_alias), do: false

  defp lock_option?(args) do
    case List.last(args) do
      opts when is_list(opts) -> Keyword.keyword?(opts) and Keyword.has_key?(opts, :lock)
      _other -> false
    end
  end

  defp relative_lib(path) do
    case String.split(path, "/lib/", parts: 2) do
      [_prefix, rest] -> "lib/" <> rest
      _other -> path
    end
  end

  defp format_hits(hits) do
    Enum.map_join(hits, "\n", fn {path, line} -> "#{path}:#{line}" end)
  end
end
