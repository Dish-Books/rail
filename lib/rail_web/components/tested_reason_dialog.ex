defmodule RailWeb.Components.TestedReasonDialog do
  @moduledoc """
  Asks why a ticket with no scenarios had nothing to test before it is marked tested.
  """
  use RailWeb, :html

  attr :issue_id, :string, required: true
  attr :identifier, :string, required: true
  attr :error, :string, default: nil

  # A remount closes the dialog, so there is no form left for recovery to refill.
  def tested_reason_dialog(assigns) do
    ~H"""
    <div
      id="tested-reason-backdrop"
      class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 p-4 pt-24 overflow-y-auto"
      phx-window-keydown="close_tested_reason"
      phx-key="Escape"
    >
      <form
        id="tested-reason-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="tested-reason-title"
        phx-submit="mark_tested"
        phx-auto-recover="ignore"
        class="w-[560px] max-w-full rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4 text-sm text-slate-900 dark:text-slate-100"
      >
        <input type="hidden" name="issue_id" value={@issue_id} />
        <div class="flex items-center justify-between gap-3 border-b border-slate-200 dark:border-slate-700 pb-3">
          <h2 id="tested-reason-title" class="text-base font-semibold min-w-0 break-words">
            Mark {@identifier} tested with no scenarios
          </h2>
          <button
            type="button"
            id="tested-reason-close"
            aria-label="Close"
            phx-click="close_tested_reason"
            class="shrink-0 p-1 rounded-sm text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="size-[18px]" />
          </button>
        </div>
        <div class="space-y-2">
          <label for="tested-reason" class="block text-sm font-semibold">Why was there nothing to test?</label>
          <textarea
            id="tested-reason"
            name="no_scenarios_reason"
            rows="3"
            maxlength="1000"
            required
            phx-mounted={JS.focus()}
            aria-describedby={if @error, do: "tested-reason-error"}
            placeholder="No tests, it was only docs"
            class="block w-full resize-y rounded-xl border-0 bg-white dark:bg-slate-900 px-4 py-3 text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-200 placeholder-slate-400 dark:placeholder-slate-500 ring-1 ring-inset ring-slate-300 dark:ring-slate-600 focus:ring-2 focus:ring-blue-500 focus:outline-none break-words"
          ></textarea>
          <p
            :if={@error}
            id="tested-reason-error"
            role="alert"
            class="text-xs text-red-700 dark:text-red-300"
          >
            {@error}
          </p>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            Required. It stays on the ticket, shown where its scenarios would be.
          </p>
        </div>
        <div class="flex items-center justify-end gap-2 pt-1">
          <.button type="button" id="tested-reason-cancel" phx-click="close_tested_reason">Cancel</.button>
          <.button type="submit" id="tested-reason-submit" variant="success" data-no-repeat>
            <.icon name="pi-check-bold" class="size-4" />Mark tested
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
