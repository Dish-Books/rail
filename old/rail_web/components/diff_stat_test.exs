defmodule RailWeb.Components.DiffStatTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RailWeb.Components.DiffStat

  test "renders additions and deletions with custom font sizes" do
    html = render_component(&diff_stat/1, additions: 15, deletions: 3, font_size: 11)

    assert html =~ "+15"
    assert html =~ "-3"
    assert html =~ "text-[11px]"
  end

  test "renders zero values as +0 and -0" do
    html = render_component(&diff_stat/1, additions: 0, deletions: 0, font_size: 10)

    assert html =~ "+0"
    assert html =~ "-0"
    assert html =~ "text-[10px]"
  end

  test "handles string and default font sizes and nil counts" do
    html10 = render_component(&diff_stat/1, font_size: "10")
    assert html10 =~ "text-[10px]"

    html11 = render_component(&diff_stat/1, font_size: "11")
    assert html11 =~ "text-[11px]"

    html12 = render_component(&diff_stat/1, font_size: 12)
    assert html12 =~ "text-xs"

    html12_str = render_component(&diff_stat/1, font_size: "12")
    assert html12_str =~ "text-xs"

    html_custom = render_component(&diff_stat/1, font_size: "text-sm", additions: nil, deletions: nil)
    assert html_custom =~ "text-sm"
    assert html_custom =~ "+0"
    assert html_custom =~ "-0"

    html_fallback = render_component(&diff_stat/1, font_size: :unknown)
    assert html_fallback =~ "text-xs"
  end

  test "renders properly via CoreComponents.diff_stat delegation" do
    html = render_component(&RailWeb.CoreComponents.diff_stat/1, additions: 2, deletions: 1)
    assert html =~ "+2"
    assert html =~ "-1"
  end
end
