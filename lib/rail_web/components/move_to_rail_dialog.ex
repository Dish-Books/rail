defmodule RailWeb.Components.MoveToRailDialog do
  @moduledoc """
  The projects page's confirmation before a Linear project moves to Rail's own tickets: what comes across, what stays,
  and that it can't be undone. An error stays in the dialog, to try again.
  """
  use RailWeb, :html

  alias Rail.Projects.Schemas.Project

  attr :project, Project, required: true
  attr :error, :string, default: nil

  def move_to_rail_dialog(assigns) do
    # Closing hands focus back to the row's Move to Rail button.
    assigns = assign(assigns, :close, JS.push(JS.focus(to: "#move-project-#{assigns.project.id}"), "close_move"))

    ~H"""
    <div
      id="move-dialog-backdrop"
      class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 p-4 pt-24 overflow-y-auto"
      phx-window-keydown={@close}
      phx-key="Escape"
    >
      <div
        id="move-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="move-title"
        class="w-[520px] max-w-full rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4 text-sm text-slate-900 dark:text-slate-100"
      >
        <div class="flex items-center justify-between gap-3 border-b border-slate-200 dark:border-slate-700 pb-3">
          <h2 id="move-title" class="text-base font-semibold min-w-0 break-words">
            Move {@project.name} off Linear?
          </h2>
          <button
            type="button"
            id="close-move-dialog"
            aria-label="Close"
            phx-click={@close}
            class="shrink-0 p-1 rounded-sm text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="size-[18px]" />
          </button>
        </div>

        <p class="text-slate-600 dark:text-slate-300 break-words">
          Rail copies every {@project.key} ticket from Linear, archived ones included, with its comments, cycles, blockers, links and files, and keeps them itself from then on.
        </p>

        <ul class="space-y-2 text-slate-600 dark:text-slate-300">
          <li class="flex gap-2">
            <.icon name="pi-check" class="size-4 text-slate-400 mt-0.5" />
            Identifiers, branches and tasks stay as they are.
          </li>
          <li class="flex gap-2">
            <.icon name="pi-check" class="size-4 text-slate-400 mt-0.5" />
            Linear stops changing these tickets, and Rail stops writing to Linear.
          </li>
          <li class="flex gap-2">
            <.icon name="pi-warning" class="size-4 text-slate-400 mt-0.5" /> It can't be undone.
          </li>
        </ul>

        <p
          :if={@error}
          id="move-error"
          role="alert"
          class="flex gap-2 rounded-md bg-red-50 dark:bg-red-400/10 ring-1 ring-inset ring-red-200 dark:ring-red-400/30 px-3 py-2 text-xs text-red-700 dark:text-red-300 min-w-0 break-words"
        >
          <.icon name="pi-warning-circle-fill" class="size-4" />
          <span class="min-w-0">{@error}</span>
        </p>

        <div class="flex justify-end gap-2 pt-2">
          <.button id="cancel-move" variant="ghost" phx-click={@close}>Cancel</.button>
          <.button
            id="confirm-move"
            variant="primary"
            phx-click="confirm_move"
            phx-value-project_id={@project.id}
            phx-mounted={JS.focus()}
          >
            Move to Rail
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
