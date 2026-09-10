defmodule RailWeb.Components.IconTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.Icon

  test "renders the Phosphor class alongside the caller's own classes" do
    html = render_component(&Icon.icon/1, name: "pi-gear-fill", id: "my-icon", class: "h-3 w-3")

    assert html =~ ~s(id="my-icon")
    assert html =~ "pi-gear-fill"
    assert html =~ "h-3 w-3"
    assert html =~ "shrink-0"
    assert html =~ ~s(aria-hidden="true")
  end

  test "size defaults when no class is given" do
    assert render_component(&Icon.icon/1, name: "pi-check") =~ "h-5 w-5"
  end
end
