defmodule RailWeb.Components.InputTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.Input

  test "renders a labelled text input with its value and attributes" do
    html =
      render_component(&Input.input/1,
        id: "role-name",
        name: "role[name]",
        label: "Display name",
        value: "Engineer",
        required: true,
        class: "font-mono",
        container_class: "col-span-2"
      )

    assert html =~ ~s(<label for="role-name")
    assert html =~ "Display name"
    assert html =~ ~s(type="text")
    assert html =~ ~s(name="role[name]")
    assert html =~ ~s(value="Engineer")
    assert html =~ "required"
    assert html =~ "font-mono"
    assert html =~ "col-span-2"
    assert html =~ "px-3.5 py-2.5"
    refute html =~ "aria-invalid"
    refute html =~ "role-name-error"
  end

  test "shows errors and marks the control invalid" do
    html = render_component(&Input.input/1, id: "role-name", name: "role[name]", errors: ["can't be blank", "too short"])

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="role-name-error")
    assert html =~ ~r{<p id="role-name-error"[^>]*>\s*can&#39;t be blank, too short\s*</p>}
    assert html =~ "border-red-500"
  end

  test "keeps other input types and sizes" do
    html = render_component(&Input.input/1, id: "n", name: "n", type: "number", value: 2, min: "1", size: "small")

    assert html =~ ~s(type="number")
    assert html =~ "px-2.5 py-1.5"
    refute html =~ "<label"
  end

  test "renders a textarea with the value as its content" do
    html = render_component(&Input.input/1, id: "d", name: "d", type: "textarea", rows: "2", value: "Owns specs")

    assert html =~ ~r{<textarea[^>]*rows="2"[^>]*>Owns specs</textarea>}
  end

  test "renders a select with its options, prompt and selected value" do
    html =
      render_component(&Input.input/1,
        id: "stage",
        name: "stage",
        type: "select",
        prompt: "Pick a stage",
        options: [{"Product", "product"}, {"Design", "design"}],
        value: "design"
      )

    assert html =~ "appearance-none"
    assert html =~ ~r{<option value="" disabled>Pick a stage</option>}
    assert html =~ ~r{<option selected value="design">Design</option>}
    assert html =~ "pi-caret-down"

    assert render_component(&Input.input/1, id: "s", name: "s", type: "select", prompt: "Pick", options: []) =~
             ~r{<option value="" disabled selected>Pick</option>}
  end

  test "renders a bare hidden input" do
    assert render_component(&Input.input/1, id: "h", name: "h", type: "hidden", value: "x") ==
             ~s(<input type="hidden" id="h" name="h" value="x">)
  end
end
