defmodule RailCredo.Checks.ActionAndUtilAccess do
  @moduledoc """
  Disallows `alias`ing, `import`ing, or fully-qualified calls into a leaf
  module under an `Actions` or `Utils` namespace - except `import`ing a Util,
  which is the only supported way to reach one.

  Actions are the public API of a context and must be reached through the
  context module. Utils are internal helpers meant to be `import`ed so their
  function names read as if they were defined locally.

      # bad
      alias Rail.Banks.Actions.CreateBankConnection
      import Rail.Sales.Actions.UpdateInvoice
      alias Rail.Billing.Utils.CalculatePlanTotal
      Rail.Billing.Utils.CalculatePlanTotal.calculate_plan_total(plan)

      # good
      Rail.Banks.create_bank_connection(scope, attrs)
      Rail.Sales.update_invoice(scope, invoice, attrs)
      import Rail.Billing.Utils.CalculatePlanTotal

  Aliasing the `Actions` or `Utils` namespace itself is allowed, since that
  is the namespace and not a specific action/util:

      # allowed
      alias RailWeb.Utils
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Actions should be called through their context module and Utils should
      be imported. Aliasing a leaf module under an `Actions` or `Utils`
      namespace, importing one under `Actions`, or calling either by its full
      name bypasses that intent.

          # bad
          alias Rail.Banks.Actions.CreateBankConnection
          CreateBankConnection.create_bank_connection(scope, attrs)

          # good
          Rail.Banks.create_bank_connection(scope, attrs)

          # bad - an action reaching a sibling action directly
          import Rail.Sales.Actions.UpdateInvoice
          update_invoice(scope, invoice, attrs)

          # good
          Rail.Sales.update_invoice(scope, invoice, attrs)

          # bad
          alias Rail.Billing.Utils.CalculatePlanTotal
          CalculatePlanTotal.calculate_plan_total(plan)

          # good
          import Rail.Billing.Utils.CalculatePlanTotal
          calculate_plan_total(plan)
      """
    ]

  alias Credo.Code.Name

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__, %{})
    result = Credo.Code.prewalk(source_file, &traverse/2, ctx)
    result.issues
  end

  defp traverse(
         {:alias, meta,
          [
            {{:., _dot_meta, [{:__aliases__, _base_meta, base_parts}, :{}]}, _call_meta,
             grouped_aliases}
            | _rest
          ]} = ast,
         ctx
       )
       when is_list(base_parts) do
    ctx =
      for {:__aliases__, _grouped_meta, tail_parts} <- grouped_aliases,
          is_list(tail_parts),
          reduce: ctx do
        ctx -> add_alias_issue(ctx, base_parts ++ tail_parts, meta)
      end

    {ast, ctx}
  end

  defp traverse({:alias, meta, [{:__aliases__, _alias_meta, module_parts} | _rest]} = ast, ctx)
       when is_list(module_parts) do
    {ast, add_alias_issue(ctx, module_parts, meta)}
  end

  defp traverse({:import, meta, [{:__aliases__, _import_meta, module_parts} | _rest]} = ast, ctx)
       when is_list(module_parts) do
    case forbidden_namespace(module_parts) do
      :actions ->
        full_name = Name.full(module_parts)
        {ast, put_issue(ctx, format_issue(ctx, import_message(full_name, meta)))}

      _allowed ->
        {ast, ctx}
    end
  end

  defp traverse(
         {{:., meta, [{:__aliases__, _alias_meta, module_parts}, function]}, _call_meta, _args} =
           ast,
         ctx
       )
       when is_list(module_parts) and is_atom(function) and function != :{} do
    {ast, add_call_issue(ctx, module_parts, meta)}
  end

  defp traverse(ast, ctx), do: {ast, ctx}

  defp add_alias_issue(ctx, module_parts, meta) do
    case forbidden_namespace(module_parts) do
      namespace when namespace in [:actions, :utils] ->
        full_name = Name.full(module_parts)
        put_issue(ctx, format_issue(ctx, alias_message(namespace, full_name, meta)))

      nil ->
        ctx
    end
  end

  defp add_call_issue(ctx, module_parts, meta) do
    case forbidden_namespace(module_parts) do
      namespace when namespace in [:actions, :utils] ->
        full_name = Name.full(module_parts)
        put_issue(ctx, format_issue(ctx, call_message(namespace, full_name, meta)))

      nil ->
        ctx
    end
  end

  defp forbidden_namespace(module_parts) do
    last_index = length(module_parts) - 1

    module_parts
    |> Enum.with_index()
    |> Enum.find_value(fn {part, index} ->
      cond do
        part == :Actions and index != last_index -> :actions
        part == :Utils and index != last_index -> :utils
        true -> nil
      end
    end)
  end

  defp alias_message(:actions, full_name, meta) do
    [
      message:
        "Do not alias `#{full_name}`. Actions should be called through their " <>
          "context module instead of being aliased directly.",
      trigger: full_name,
      line_no: meta[:line]
    ]
  end

  defp alias_message(:utils, full_name, meta) do
    [
      message:
        "Do not alias `#{full_name}`. Utils should be `import`ed so their " <>
          "functions read as if defined locally.",
      trigger: full_name,
      line_no: meta[:line]
    ]
  end

  defp call_message(:actions, full_name, meta) do
    [
      message:
        "Do not call `#{full_name}` directly. Actions should be called through " <>
          "their context module.",
      trigger: full_name,
      line_no: meta[:line]
    ]
  end

  defp call_message(:utils, full_name, meta) do
    [
      message:
        "Do not call `#{full_name}` by its full name. Utils must be `import`ed " <>
          "so their functions read as if defined locally.",
      trigger: full_name,
      line_no: meta[:line]
    ]
  end

  defp import_message(full_name, meta) do
    [
      message:
        "Do not import `#{full_name}`. Actions should be called through their " <>
          "context module. Shared helpers belong in a Util.",
      trigger: full_name,
      line_no: meta[:line]
    ]
  end
end
