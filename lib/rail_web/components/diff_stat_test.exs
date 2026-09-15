defmodule RailWeb.Components.DiffStatTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.DiffStat

  test "draws both counts, zeroes included, so the columns line up" do
    html = render_component(&DiffStat.diff_stat/1, additions: 4, deletions: 0)

    assert html =~ "+4"
    assert html =~ "-0"
    assert html =~ "text-xs"
  end

  test "takes the smaller sizes the file tree and header ask for" do
    assert render_component(&DiffStat.diff_stat/1, additions: 1, deletions: 1, font_size: 10) =~ "text-[10px]"
    assert render_component(&DiffStat.diff_stat/1, additions: 1, deletions: 1, font_size: 11) =~ "text-[11px]"
  end
end
