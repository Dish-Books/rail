defmodule RailWeb.Components.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.Markdown

  test "wraps the rendered markdown in the prose body" do
    html = render_component(&Markdown.markdown/1, content: "Some **bold**", class: "extra")

    assert html =~ ~s(data-qa="markdown-body")
    assert html =~ "extra"
    assert html =~ "<strong>bold</strong>"
  end

  test "renders an empty body for no content" do
    assert render_component(&Markdown.markdown/1, content: nil) =~ ~s(data-qa="markdown-body")
  end
end
