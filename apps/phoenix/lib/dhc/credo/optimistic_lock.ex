defmodule Dhc.Credo.OptimisticLock do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Mutable ADR 0023 entities must retain their optimistic-concurrency
      witness. Struct writes require
      Ecto.Changeset.optimistic_lock(:lock_version); bulk writes require
      inc: [lock_version: 1].
      """
    ]

  @repo_writes [:update, :update!, :delete, :delete!]
  @multi_writes [:update, :delete]
  @versioned_schema_names [
    :Item,
    :Container,
    :EquipmentCategory,
    :Workshop,
    :Registration,
    :WaitlistEntry,
    :MemberProfile,
    :UserProfile,
    :Setting
  ]
  @versioned_tables ~w(
    inventory_items
    containers
    equipment_categories
    workshops
    workshop_registrations
    waitlist_entries
    member_profiles
    user_profiles
    settings
  )
  @versioned_variable_names [
    :item,
    :container,
    :category,
    :workshop,
    :registration,
    :entry,
    :member_profile,
    :user_profile,
    :waitlist_profile,
    :setting
  ]

  @impl true
  def exit_status, do: 1

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if domain_source?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      Credo.Code.prewalk(source_file, fn
        {definition_kind, _meta, [_head, [do: body]]} = definition, issues
        when definition_kind in [:def, :defp] ->
          {definition, function_issues(body, issue_meta, issues)}

        ast, issues ->
          {ast, issues}
      end)
    else
      []
    end
  end

  defp function_issues(body, issue_meta, issues) do
    {_body, issues} =
      Macro.prewalk(body, issues, fn ast, acc ->
        case issue_for_write(ast, body, issue_meta) do
          nil -> {ast, acc}
          issue -> {ast, [issue | acc]}
        end
      end)

    issues
  end

  defp domain_source?(%SourceFile{filename: filename}) do
    String.starts_with?(filename, "lib/dhc/")
  end

  defp issue_for_write({:|>, _pipe_meta, [value, repo_write]}, body, issue_meta) do
    case repo_write do
      {{:., _, [_repo, function]}, meta, []} when function in @repo_writes ->
        missing_lock_issue(value, body, function, meta, issue_meta)

      {{:., _, [_multi, function]}, meta, [_, _ | _] = args} when function in @multi_writes ->
        missing_lock_issue(List.last(args), body, "Ecto.Multi.#{function}", meta, issue_meta)

      {{:., _, [repo, :update_all]}, meta, [updates]} ->
        if repo?(repo) and versioned_context?(value, body) and
             not increments_lock_version?(updates) do
          bulk_write_issue(meta, issue_meta)
        end

      _ ->
        nil
    end
  end

  defp issue_for_write({{:., _, [repo, function]}, meta, [changeset]}, body, issue_meta)
       when function in @repo_writes do
    if repo?(repo), do: missing_lock_issue(changeset, body, function, meta, issue_meta)
  end

  defp issue_for_write({{:., _, [repo, :update_all]}, meta, [query, updates]}, body, issue_meta) do
    if repo?(repo) and versioned_context?(query, body) and not increments_lock_version?(updates) do
      bulk_write_issue(meta, issue_meta)
    end
  end

  defp issue_for_write(_ast, _body, _issue_meta), do: nil

  defp missing_lock_issue(changeset, body, function, meta, issue_meta) do
    if versioned_context?(changeset, body) and not optimistic_lock?(changeset, body) do
      format_issue(
        issue_meta,
        message:
          "Use Ecto.Changeset.optimistic_lock(:lock_version) before this write to an ADR 0023 entity.",
        trigger: to_string(function),
        line_no: meta[:line],
        column: meta[:column]
      )
    end
  end

  defp bulk_write_issue(meta, issue_meta) do
    format_issue(
      issue_meta,
      message: "Include inc: [lock_version: 1] in this bulk write to an ADR 0023 entity.",
      trigger: "Repo.update_all",
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp repo?({:__aliases__, _, aliases}), do: List.last(aliases) == :Repo
  defp repo?(_), do: false

  defp optimistic_lock?(changeset, body) do
    contains_optimistic_lock?(changeset) or
      (variable?(changeset) and variable_assignment_contains_lock?(body, changeset))
  end

  defp variable_assignment_contains_lock?(body, variable) do
    contains?(body, fn
      {:=, _, [^variable, value]} -> contains_optimistic_lock?(value)
      _ -> false
    end)
  end

  defp contains_optimistic_lock?(ast) do
    contains?(ast, fn
      {{:., _, [changeset, :optimistic_lock]}, _, [_value, :lock_version]} ->
        changeset_module?(changeset)

      {:|>, _, [_value, {{:., _, [changeset, :optimistic_lock]}, _, [:lock_version]}]} ->
        changeset_module?(changeset)

      _ ->
        false
    end)
  end

  defp changeset_module?({:__aliases__, _, aliases}),
    do: Enum.take(aliases, -2) == [:Ecto, :Changeset]

  defp changeset_module?(_), do: false

  defp versioned_context?(ast, body) do
    contains_versioned_resource?(ast) or
      (variable?(ast) and
         (versioned_variable?(ast) or variable_assignment_contains_resource?(body, ast)))
  end

  defp variable_assignment_contains_resource?(body, variable) do
    contains?(body, fn
      {:=, _, [^variable, value]} -> contains_versioned_resource?(value)
      _ -> false
    end)
  end

  defp versioned_variable?({name, _meta, _context}), do: name in @versioned_variable_names

  defp contains_versioned_resource?(ast) do
    contains?(ast, fn
      {:__aliases__, _, aliases} -> List.last(aliases) in @versioned_schema_names
      value when is_binary(value) -> value in @versioned_tables
      variable when is_tuple(variable) -> variable?(variable) and versioned_variable?(variable)
      _ -> false
    end)
  end

  defp increments_lock_version?(ast) do
    contains?(ast, fn
      {:inc, values} when is_list(values) -> Keyword.get(values, :lock_version) == 1
      _ -> false
    end)
  end

  defp variable?({name, _meta, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp variable?(_), do: false

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end
end
