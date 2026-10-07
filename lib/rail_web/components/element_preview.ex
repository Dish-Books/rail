defmodule RailWeb.Components.ElementPreview do
  @moduledoc """
  A design comment's element as it was captured, drawn alone at its own size in a frame with every sandbox
  restriction on, so nothing in it runs or reaches Rail's page. It carries only its own styles, so may look unstyled.
  """
  use RailWeb, :html

  # Ahead of the element, so the browser's own margins cannot push it out of the box it was captured at.
  @reset "<style>html,body{margin:0;overflow:hidden}body>*:first-child{margin:0}</style>"

  attr :id, :string, required: true
  attr :capture, :map, required: true, doc: "the element's `html`, `width` and `height`, as an observation keeps it"
  attr :class, :any, default: nil

  # The HTML only ever reaches the page as the srcdoc attribute's escaped value.
  def element_preview(assigns) do
    assigns = assign(assigns, :reset, @reset)

    ~H"""
    <figure id={@id} data-qa="element_preview" class={["space-y-1.5 min-w-0", @class]}>
      <div class="max-w-full overflow-hidden">
        <div
          id={"#{@id}-fit"}
          phx-hook="ElementPreview"
          phx-update="ignore"
          data-width={@capture["width"]}
          data-height={@capture["height"]}
          class="relative max-w-full overflow-hidden rounded-lg border border-slate-200 dark:border-slate-700 bg-white"
          style={"width: #{@capture["width"]}px; height: #{@capture["height"]}px;"}
        >
          <iframe
            id={"#{@id}-frame"}
            title="The element as it looked in the mockup"
            sandbox=""
            srcdoc={@reset <> @capture["html"]}
            tabindex="-1"
            class="absolute top-0 left-0 border-0 pointer-events-none"
            style={"width: #{@capture["width"]}px; height: #{@capture["height"]}px;"}
          />
        </div>
      </div>
      <figcaption class="text-[11px] text-slate-500 dark:text-slate-400">
        As it looked in the mockup, at its own size
      </figcaption>
    </figure>
    """
  end
end
