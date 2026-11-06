defmodule RailWeb.Components.ReviewedToggle do
  @moduledoc """
  The Reviewed button a diff file and a plan card share, pressed once the reader has marked it.
  """
  use RailWeb, :html

  attr :reviewed, :boolean, required: true
  attr :rest, :global

  def reviewed_toggle(assigns) do
    ~H"""
    <button
      type="button"
      aria-pressed={to_string(@reviewed)}
      class={[
        "shrink-0 inline-flex items-center gap-1.5 pl-1.5 pr-2.5 py-1 rounded-lg border text-xs font-semibold cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
        @reviewed && "border-emerald-500/40 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
        not @reviewed &&
          "border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
      ]}
      {@rest}
    >
      <span class={[
        "size-4 grid place-items-center rounded border",
        @reviewed && "border-emerald-500 bg-emerald-500 text-white",
        not @reviewed && "border-slate-300 dark:border-slate-600"
      ]}>
        <.icon :if={@reviewed} name="pi-check" class="size-3" />
      </span>
      Reviewed
    </button>
    """
  end
end
