defmodule Rail.Tools.Utils.ActionSpaceTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.ActionSpace

  # What the snapshot actually returns for a small form: a field appears twice,
  # once to be typed into and once to be clicked, and a dropdown appears once per
  # option it offers.
  @actions [
    %{"id" => "e1", "node" => 1, "kind" => "fill", "role" => "textbox", "label" => "Amount", "value" => ""},
    %{"id" => "e2", "node" => 1, "kind" => "click", "role" => "textbox", "label" => "Open Amount", "value" => ""},
    %{
      "id" => "e3",
      "node" => 2,
      "kind" => "select",
      "role" => "combobox",
      "label" => "Category → Food",
      "value" => "food",
      "current_value" => "Pick one"
    },
    %{
      "id" => "e4",
      "node" => 2,
      "kind" => "select",
      "role" => "combobox",
      "label" => "Category → Drink",
      "value" => "drink",
      "current_value" => "Pick one"
    },
    %{"id" => "e5", "node" => 3, "kind" => "click", "role" => "button", "label" => "Save", "value" => ""},
    %{"id" => "scroll_down", "kind" => "scroll", "label" => "Scroll down", "delta" => 560},
    %{"id" => "wait", "kind" => "wait", "label" => "Wait for the page to update"}
  ]

  test "numbers each element once, however many things can be done to it" do
    {elements, _targets, _controls} = action_space(@actions)

    assert Enum.map(elements, & &1["index"]) == ["1", "2", "3"]
    assert Enum.map(elements, & &1["label"]) == ["Amount", "Category", "Save"]
  end

  test "an element says which operations it will accept" do
    {elements, _targets, _controls} = action_space(@actions)

    assert [amount, category, save] = elements
    assert amount["operations"] == ["TYPE_TEXT", "CLICK"]
    assert category["operations"] == ["SELECT"]
    assert save["operations"] == ["CLICK"]
  end

  # A question about where to click is only ever offered things that can be
  # clicked, which is what makes an answer executable without further checking.
  test "each operation is offered only its own targets" do
    {_elements, targets, _controls} = action_space(@actions)

    assert targets |> Map.keys() |> Enum.sort() == ["CLICK", "SELECT", "TYPE_TEXT"]
    assert targets["CLICK"] |> Map.keys() |> Enum.sort() == ["1", "3"]
    assert Map.keys(targets["TYPE_TEXT"]) == ["1"]
    assert targets["SELECT"] |> Map.keys() |> Enum.sort() == ["2:1", "2:2"]
  end

  test "a target carries the action that executes it" do
    {_elements, targets, _controls} = action_space(@actions)

    assert %{"id" => "e5", "node" => 3, "kind" => "click"} = targets["CLICK"]["3"]
    assert %{"id" => "e1", "kind" => "fill"} = targets["TYPE_TEXT"]["1"]
  end

  # Choosing a dropdown value is choosing an option, so the options are numbered
  # inside the element that offers them and the element shows what it holds now.
  test "a dropdown offers its options and says what it currently holds" do
    {elements, _targets, _controls} = action_space(@actions)

    assert [_amount, category, _save] = elements
    assert category["value"] == "Pick one"

    assert category["options"] == [
             %{"index" => "2:1", "label" => "Category → Food", "value" => "food"},
             %{"index" => "2:2", "label" => "Category → Drink", "value" => "drink"}
           ]
  end

  test "scrolling and waiting take no target and are kept aside" do
    {_elements, targets, controls} = action_space(@actions)

    assert controls |> Map.keys() |> Enum.sort() == ["SCROLL_DOWN", "WAIT"]
    assert %{"kind" => "scroll", "delta" => 560} = controls["SCROLL_DOWN"]
    refute Map.has_key?(targets, "SCROLL_DOWN")
  end

  test "a page with nothing on it offers nothing" do
    assert {[], %{}, %{}} = action_space([])
  end

  test "an element carries the state a choice turns on" do
    checkbox = %{
      "id" => "e1",
      "node" => 9,
      "kind" => "click",
      "role" => "checkbox",
      "label" => "Reviewed",
      "checked" => "true",
      "expanded" => "false"
    }

    assert {[element], _targets, _controls} = action_space([checkbox])
    assert %{"checked" => "true", "expanded" => "false", "role" => "checkbox"} = element
  end
end
