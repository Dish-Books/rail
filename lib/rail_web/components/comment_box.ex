defmodule RailWeb.Components.CommentBox do
  @moduledoc """
  The box a comment is written in, on a diff line, an element of a design or a line of the ticket or plan: Cancel, Escape or Save comment
  closes it, and only its author sees what it saves until they send it.
  """
  use RailWeb, :html

  attr :id, :string, required: true, doc: "the form's id; mounting a new one takes the focus"
  attr :body_id, :string, required: true
  attr :qa, :string, required: true, doc: "prefixes the form's, the body's and the buttons' data-qa"
  attr :label, :string, required: true, doc: "what the comment is on, for the body's label"
  attr :body, :string, default: nil
  attr :submit, :string, required: true
  attr :change, :string, required: true
  attr :cancel, :string, required: true
  attr :target, :any, required: true
  attr :class, :any, default: "max-w-[760px] shadow-xs"
  attr :rest, :global

  slot :heading

  def comment_box(assigns) do
    ~H"""
    <form
      id={@id}
      data-qa={"#{@qa}_form"}
      phx-submit={@submit}
      phx-change={@change}
      phx-target={@target}
      class={[
        "rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 p-2",
        @class
      ]}
      {@rest}
    >
      {render_slot(@heading)}
      <textarea
        id={@body_id}
        name="body"
        data-qa={"#{@qa}_body"}
        aria-label={"Comment on #{@label}"}
        phx-mounted={JS.focus()}
        phx-keydown={@cancel}
        phx-key="Escape"
        phx-target={@target}
        phx-debounce="300"
        phx-no-format
        class="block w-full min-h-[52px] resize-y px-3 py-2 text-sm leading-[18px] rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:border-blue-600 dark:focus:border-blue-500 focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
      >{@body}</textarea>

      <div class="mt-1.5 flex items-center gap-2">
        <span class="pl-1 min-w-0 truncate text-[11px] text-slate-500 dark:text-slate-400">
          Only you see this until you send it.
        </span>
        <button
          type="button"
          phx-click={@cancel}
          phx-target={@target}
          data-qa={"#{@qa}_cancel"}
          class="ml-auto shrink-0 whitespace-nowrap px-3 py-1.5 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
        >
          Cancel
        </button>
        <button
          type="submit"
          data-qa={"#{@qa}_save"}
          class="shrink-0 whitespace-nowrap inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs cursor-pointer"
        >
          <.icon name="pi-check" class="size-4" />Save comment
        </button>
      </div>
    </form>
    """
  end
end
