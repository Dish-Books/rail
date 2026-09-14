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

  @linear_uploads "https://uploads.linear.app/"

  @doc """
  Transforms a markdown string into safe HTML.

  Linear serves an uploaded file only to a token, so with an `assets_base` the
  images it holds are pointed at that path instead, for Rail to fetch and serve.
  """
  def render_markdown(content, assets_base \\ nil)

  def render_markdown(content, _assets_base) when content in [nil, ""], do: ""

  def render_markdown(content, assets_base) when is_binary(content) do
    content |> MDEx.to_html!(@options) |> point_at(assets_base)
  end

  defp point_at(html, nil), do: html
  defp point_at(html, assets_base), do: String.replace(html, @linear_uploads, "#{assets_base}/")
end
