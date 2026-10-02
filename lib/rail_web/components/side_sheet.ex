defmodule RailWeb.Components.SideSheet do
  @moduledoc """
  A panel pinned to the right under the top bar. It is not modal: the page behind stays clickable.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the sheet is about, for screen readers"
  attr :on_close, :any, required: true, doc: "the event the close button and Escape send"

  slot :header, required: true
  slot :inner_block, required: true

  def side_sheet(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label={@label}
      phx-window-keydown={@on_close}
      phx-key="Escape"
      class="fixed right-0 top-[52px] bottom-0 w-[440px] max-w-full z-30 flex flex-col border-l border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800 shadow-2xl"
    >
      <div class="flex items-start gap-3 p-5 border-b border-slate-200 dark:border-slate-700">
        <div class="flex-1 min-w-0">{render_slot(@header)}</div>
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click={@on_close}
          aria-label="Close"
          class="h-8 w-8 shrink-0 rounded-md flex items-center justify-center text-slate-400 hover:bg-slate-200 dark:hover:bg-slate-700 cursor-pointer"
        >
          <.icon name="pi-x" class="h-4 w-4" />
        </button>
      </div>
      <div data-qa="side-sheet-body" class="flex-1 overflow-y-auto p-5 space-y-6">
        {render_slot(@inner_block)}
      </div>
    </aside>
    """
  end
end
