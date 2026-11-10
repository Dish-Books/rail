defmodule RailWeb.Components.CycleDatesModal do
  @moduledoc """
  The Edit dates dialog for a Rail-tracked cycle, drawn from the changeset its page holds. It raises
  `validate_cycle_dates`, `save_cycle_dates` and `close_cycle_dates`.
  """
  use RailWeb, :html

  # The cycle as `Rail.Issues.get_cycles/1` reads it, for its name and status.
  attr :cycle, :map, required: true
  attr :changeset, Ecto.Changeset, required: true

  def cycle_dates_modal(assigns) do
    changeset = assigns.changeset
    errors = if changeset.action, do: Enum.map(changeset.errors, fn {_field, {message, _opts}} -> message end), else: []

    assigns =
      assigns
      |> assign(:label, assigns.cycle.name || "Cycle #{assigns.cycle.number}")
      |> assign(:locked, assigns.cycle.status == :running)
      |> assign(:errors, Enum.uniq(errors))
      |> assign(:starts_on, Ecto.Changeset.get_field(changeset, :starts_on))
      |> assign(:ends_on, Ecto.Changeset.get_field(changeset, :ends_on))

    ~H"""
    <div
      id="cycle-dates-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      phx-window-keydown="close_cycle_dates"
      phx-key="Escape"
    >
      <div
        id="cycle-dates-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="cycle-dates-title"
        class="w-full max-w-lg rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4"
      >
        <div class="flex items-center justify-between gap-3 border-b border-slate-200 dark:border-slate-700 pb-3">
          <h2
            id="cycle-dates-title"
            class="min-w-0 break-words text-base font-semibold text-slate-900 dark:text-slate-100"
          >
            Edit {@label} dates
          </h2>
          <button
            type="button"
            id="cycle-dates-close"
            aria-label="Close"
            phx-click="close_cycle_dates"
            class="shrink-0 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 text-sm font-bold p-1 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
          >
            ✕
          </button>
        </div>

        <.form
          for={@changeset}
          id="cycle-dates-form"
          phx-change="validate_cycle_dates"
          phx-submit="save_cycle_dates"
          class="space-y-4"
        >
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label
                for="cycle-dates-starts"
                class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
              >
                Starts
              </label>
              <input
                type="date"
                id="cycle-dates-starts"
                name="cycle[starts_on]"
                value={@starts_on}
                disabled={@locked}
                phx-mounted={!@locked && JS.focus()}
                class={[
                  "w-full px-3 py-2 text-sm rounded-lg border bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500",
                  if(@errors == [],
                    do: "border-slate-500 dark:border-slate-400",
                    else: "border-red-500 dark:border-red-400"
                  ),
                  @locked && "opacity-60 cursor-not-allowed"
                ]}
              />
              <p
                :if={@locked}
                id="cycle-dates-start-locked"
                class="mt-1 text-xs text-slate-500 dark:text-slate-400"
              >
                A running cycle keeps its start
              </p>
            </div>
            <div>
              <label
                for="cycle-dates-ends"
                class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
              >
                Ends
              </label>
              <input
                type="date"
                id="cycle-dates-ends"
                name="cycle[ends_on]"
                value={@ends_on}
                phx-mounted={@locked && JS.focus()}
                class={[
                  "w-full px-3 py-2 text-sm rounded-lg border bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500",
                  if(@errors == [],
                    do: "border-slate-500 dark:border-slate-400",
                    else: "border-red-500 dark:border-red-400"
                  )
                ]}
              />
            </div>
          </div>

          <p class="text-xs text-slate-500 dark:text-slate-400">
            Later cycles move by as many days as the end does.
          </p>

          <div
            :if={@errors != []}
            id="cycle-dates-error"
            role="alert"
            class="p-2.5 rounded-lg bg-red-500/10 border border-red-500/30 text-red-600 dark:text-red-300 text-xs font-medium flex items-start gap-2"
          >
            <.icon name="pi-warning-circle-fill" class="size-3.5 mt-px" />
            <span class="min-w-0 break-words">{Enum.join(@errors, " ")}</span>
          </div>

          <div class="flex items-center justify-end gap-3 pt-3 border-t border-slate-200 dark:border-slate-700">
            <button
              type="button"
              id="cycle-dates-cancel"
              phx-click="close_cycle_dates"
              class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              Cancel
            </button>
            <button
              type="submit"
              id="cycle-dates-save"
              phx-disable-with="Saving..."
              class="px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold shadow-xs hover:opacity-90 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-400"
            >
              Save dates
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
