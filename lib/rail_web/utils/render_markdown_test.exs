defmodule RailWeb.Utils.RenderMarkdownTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.RenderMarkdown

  test "renders empty string for nil and empty content" do
    assert render_markdown(nil) == ""
    assert render_markdown("") == ""
  end

  test "renders headings h1, h2, h3, h4" do
    content = "# Title\n## Subtitle\n### Section\n#### Sub-section"
    html = render_markdown(content)

    assert html =~ "<h1"
    assert html =~ "Title</h1>"
    assert html =~ "<h2"
    assert html =~ "Subtitle</h2>"
    assert html =~ "<h3"
    assert html =~ "Section</h3>"
    assert html =~ "<h4"
    assert html =~ "Sub-section</h4>"
  end

  test "renders bold, italic, code, links, and blockquotes" do
    content = "> A blockquote\n\nSome **bold** and _italic_ and `inline_code` with [Linear](https://linear.app)"
    html = render_markdown(content)

    assert html =~ "<blockquote"
    assert html =~ "A blockquote</blockquote>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<em>italic</em>"
    assert html =~ "<code"
    assert html =~ "inline_code</code>"
    assert html =~ "<a href=\"https://linear.app\""
    assert html =~ "Linear</a>"
  end

  test "renders italic fallback for _No ticket body yet._" do
    content = "_No ticket body yet._"
    html = render_markdown(content)

    assert html =~ "<em>No ticket body yet.</em>"
  end

  test "renders unordered and ordered lists" do
    content = "- Apple\n- Banana\n\n1. First\n2. Second"
    html = render_markdown(content)

    assert html =~ "<ul class=\"list-disc"
    assert html =~ "Apple</li>"
    assert html =~ "Banana</li>"

    assert html =~ "<ol class=\"list-decimal"
    assert html =~ "First</li>"
    assert html =~ "Second</li>"
  end

  test "renders fenced code blocks with escaped HTML" do
    content = "```elixir\ndef hello, do: \"<script>alert(1)</script>\"\n```"
    html = render_markdown(content)

    assert html =~ "<pre"
    assert html =~ "<code"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>"
  end

  test "handles plain strings and unclosed code blocks and blockquotes at EOF" do
    assert render_markdown("Plain string") =~ "Plain string"

    unclosed_code = "```elixir\ndef unclosed, do: :ok"
    html_code = render_markdown(unclosed_code)
    assert html_code =~ "<pre"

    unclosed_quote = "> line without ending"
    html_quote = render_markdown(unclosed_quote)
    assert html_quote =~ "<blockquote"

    assert render_markdown("#hashtag") =~ "#hashtag"
  end
end
