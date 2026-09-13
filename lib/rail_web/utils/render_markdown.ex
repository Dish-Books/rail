defmodule RailWeb.Utils.RenderMarkdown do
  @moduledoc """
  Renders markdown — Linear descriptions and comments, agent tickets and replies —
  as HTML with GitHub's extensions.

  Raw HTML in the source is escaped and dangerous links are dropped, so the
  output is safe to put on the page as-is.
  """

  @options [
    extension: [autolink: true, strikethrough: true, table: true, tasklist: true],
    render: [escape: true, unsafe: false]
  ]

  @doc """
  Transforms a markdown string into safe HTML.
  """
  def render_markdown(nil), do: ""
  def render_markdown(""), do: ""
  def render_markdown(content) when is_binary(content), do: MDEx.to_html!(content, @options)
end
