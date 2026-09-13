defmodule RailWeb.Utils.RenderMarkdownTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.RenderMarkdown

  test "no content renders nothing" do
    assert render_markdown(nil) == ""
    assert render_markdown("") == ""
  end

  test "renders prose, lists, code and links" do
    html = render_markdown("# Title\n\nSome **bold** and `code` with [Linear](https://linear.app)\n\n- one\n  - nested")

    assert html =~ "<h1>Title</h1>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code>code</code>"
    assert html =~ ~s(<a href="https://linear.app">Linear</a>)
    assert html =~ ~r/<li>one\s*<ul>\s*<li>nested<\/li>/
  end

  test "renders GitHub tables, task lists and strikethrough" do
    html = render_markdown("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n- [ ] todo\n\n~~gone~~")

    assert html =~ "<table>"
    assert html =~ "<td>1</td>"
    assert html =~ ~s(type="checkbox")
    assert html =~ "<del>gone</del>"
  end

  test "raw HTML is escaped, not rendered" do
    html = render_markdown("<script>alert(1)</script>\n\nA <b>tag</b>")

    refute html =~ "<script>"
    refute html =~ "<b>"
    assert html =~ "&lt;script&gt;"
  end

  test "dangerous links are dropped" do
    html = render_markdown("[click](javascript:alert(1))")

    refute html =~ "javascript:"
  end
end
