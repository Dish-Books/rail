defmodule RailWeb.Components.Markdown do
  @moduledoc """
  Component for rendering sanitized, safe markdown prose.
  """
  use RailWeb, :html

  attr :content, :string, default: ""
  attr :class, :string, default: nil
  attr :assets_base, :string, default: nil

  def markdown(assigns) do
    ~H"""
    <div
      data-qa="markdown-body"
      class={["prose prose-slate dark:prose-invert max-w-none text-sm leading-relaxed", @class]}
    >
      {raw(render_markdown(@content, @assets_base))}
    </div>
    """
  end
end
