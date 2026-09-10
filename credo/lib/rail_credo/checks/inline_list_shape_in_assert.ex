defmodule RailCredo.Checks.InlineListShapeInAssert do
  @moduledoc """
  Flags `[_first, _second] = var` placeholder lists inside `assert`.

  When verifying the structure of a return value, put the expected fields
  directly into the `assert`'s pattern instead of binding a list of underscore
  placeholders and reaching into `var` from a later assertion. The pattern
  doubles as the spec for the expected response, kept in one place and easier
  to read against the production code.

      # bad
      assert %{metrics: [_first, _second] = metrics} =
               Reports.build_location_performance(scope, ...)

      assert Enum.map(metrics, & &1.name) == ["Location A", "Location B"]

      # good
      assert %{metrics: [%{name: "Location A"}, %{name: "Location B"}]} =
               Reports.build_location_performance(scope, ...)

  Triggered when every element of the list is a bare underscore-prefixed
  variable (e.g. `[_first, _second]`) and the whole list is bound to a name
  (e.g. `= metrics`). Mixed patterns like `[%{name: "A"}, _second]` are not
  flagged because the named element already carries intent.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Inside `assert`, replace `[_x, _y] = var` placeholders with the expected
      element shape. If you only bind `var` to read fields from it later, fold
      those fields into the pattern.

          # bad
          assert %{items: [_a, _b] = items} = call()
          assert Enum.map(items, & &1.id) == [1, 2]

          # good
          assert %{items: [%{id: 1}, %{id: 2}]} = call()
      """
    ]

  @impl true
  def run(%SourceFile{filename: filename} = source_file, params) do
    if test_file?(filename) do
      ctx = Context.build(source_file, params, __MODULE__, %{})
      result = Credo.Code.prewalk(source_file, &traverse/2, ctx)
      result.issues
    else
      []
    end
  end

  defp test_file?(filename), do: String.ends_with?(filename, "_test.exs")

  defp traverse({:assert, _meta, args} = ast, ctx) when is_list(args) do
    {_walked, lines} =
      Macro.prewalk(args, [], fn
        {:=, eq_meta, [list_pattern, {var, _var_meta, nil}]} = node, acc
        when is_list(list_pattern) and is_atom(var) ->
          if placeholder_list?(list_pattern) do
            {node, [eq_meta[:line] | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    ctx = Enum.reduce(lines, ctx, &add_issue(&2, &1))
    {ast, ctx}
  end

  defp traverse(ast, ctx), do: {ast, ctx}

  defp placeholder_list?([]), do: false

  defp placeholder_list?(list) do
    Enum.all?(list, fn
      {atom, _meta, nil} when is_atom(atom) ->
        atom |> Atom.to_string() |> String.starts_with?("_")

      _other ->
        false
    end)
  end

  defp add_issue(ctx, line) do
    put_issue(
      ctx,
      format_issue(ctx,
        message:
          "Replace `[_x, _y] = var` placeholders inside `assert` with the expected element shape. " <>
            "The pattern is the spec for the expected response.",
        trigger: "[_, _] = ",
        line_no: line
      )
    )
  end
end
