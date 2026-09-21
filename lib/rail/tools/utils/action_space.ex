defmodule Rail.Tools.Utils.ActionSpace do
  @moduledoc """
  Turns what was observed on a page into the choices a decision can be made from.

  The snapshot lists one entry per thing that could be done - a field appears once
  to be typed into and again to be clicked, a dropdown once per option it offers.
  That is the right shape to execute from and the wrong shape to choose from, so
  it is folded into two: a numbered table of elements, and, for each operation, the
  targets that operation could be applied to.

  Numbering them is what keeps model output away from the page. An answer is an
  index into a table Rail built from nodes it observed, so the worst a wrong
  answer can do is act on the wrong element that was really there - never on a
  selector nobody checked.

  Each operation gets its own target list, so a question about where to click is
  only ever offered things that can be clicked. Scrolling and waiting take no
  target at all and are kept aside as controls.
  """

  @operations %{"click" => "CLICK", "fill" => "TYPE_TEXT", "select" => "SELECT"}

  @carried ["role", "value", "checked", "selected", "expanded"]

  @doc """
  Returns `{elements, targets, controls}` for the actions in a snapshot.

  `elements` is the table in the order it is numbered from 1. `targets` maps an
  operation to its own targets, each keyed by the element's index - or by
  `"index:option"` for a dropdown, since choosing a `SELECT` means choosing a
  value rather than only a control. `controls` are the operations that take no
  target, keyed the way they are offered.
  """
  def action_space(actions) when is_list(actions) do
    actions
    |> Enum.reduce(%{order: [], elements: %{}, indices: %{}, targets: %{}, controls: %{}}, &place/2)
    |> unfold()
  end

  defp place(%{"kind" => kind} = action, state) when is_map_key(@operations, kind) do
    {index, state} = index_for(action, state)
    operation = @operations[kind]
    {target, state} = target_for(kind, index, action, state)

    state
    |> update_in([:elements, index, "operations"], &Enum.uniq([operation | &1]))
    |> put_in([:targets, Access.key(operation, %{}), target], action)
  end

  defp place(%{"id" => id} = action, state) do
    put_in(state, [:controls, String.upcase(id)], action)
  end

  # One entry per element however many things can be done to it, so the table
  # reads as a page rather than as a list of operations.
  defp index_for(%{"node" => node} = action, %{indices: indices} = state) do
    case indices[node] do
      index when is_binary(index) ->
        {index, state}

      nil ->
        index = to_string(map_size(indices) + 1)

        state =
          state
          |> put_in([:indices, node], index)
          |> put_in([:elements, index], element(index, action))
          |> update_in([:order], &[index | &1])

        {index, state}
    end
  end

  defp element(index, action) do
    action
    |> Map.take(@carried)
    |> Map.merge(%{"index" => index, "label" => label(action), "operations" => []})
    |> Map.merge(dropdown(action))
  end

  # A dropdown shows the value it currently holds rather than the option this
  # entry happens to be, and carries the options it offers.
  defp dropdown(%{"kind" => "select"} = action) do
    %{"value" => Map.get(action, "current_value", ""), "options" => []}
  end

  defp dropdown(_other), do: %{}

  # A dropdown's entries are labelled "Category → Food"; the element is the
  # dropdown, so it takes the part before the arrow and the options take the rest.
  defp label(%{"label" => label}), do: label |> String.split(" → ") |> List.first()

  # Choosing a dropdown value is choosing an option rather than a control, so its
  # targets are numbered within the element that offers them.
  defp target_for("select", index, action, state) do
    options = get_in(state, [:elements, index, "options"]) || []
    target = "#{index}:#{length(options) + 1}"

    option = %{"index" => target, "label" => action["label"], "value" => action["value"]}

    {target, update_in(state, [:elements, index, "options"], &[option | &1])}
  end

  defp target_for(_kind, index, _action, state), do: {index, state}

  # Everything accumulated newest-first so that nothing was appended to a list one
  # item at a time - a dropdown can offer hundreds of options. The order the
  # reader sees is restored here, once.
  defp unfold(%{order: order, elements: elements, targets: targets, controls: controls}) do
    {order |> Enum.reverse() |> Enum.map(&ordered(elements[&1])), targets, controls}
  end

  defp ordered(element) do
    element
    |> Map.update!("operations", &Enum.reverse/1)
    |> Map.replace_lazy("options", &Enum.reverse/1)
  end
end
