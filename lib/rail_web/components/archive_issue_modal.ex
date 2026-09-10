defmodule RailWeb.Components.ArchiveIssueModal do
  @moduledoc false
  use RailWeb, :html

  attr :issue, :map, default: nil
  attr :visible, :boolean, default: false

  def archive_issue_modal(assigns) do
    ~H"""
    <div
      :if={@visible and @issue != nil}
      id="archive-issue-dialog"
      data-qa="archive-issue-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <div class="w-full max-w-md rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4">
        <h2
          class="text-base font-semibold text-slate-900 dark:text-slate-100"
          id="archive-modal-title"
        >
          Archive {@issue.identifier}?
        </h2>

        <p class="text-xs text-slate-500 dark:text-slate-400" id="archive-modal-body">
          This archives "{@issue.title}" and marks it as canceled in Linear.
        </p>

        <div class="flex justify-end space-x-3 pt-3">
          <button
            type="button"
            id="cancel-archive-button"
            data-qa="cancel-archive-button"
            phx-click="close_archive"
            class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
          >
            Cancel
          </button>

          <button
            type="button"
            id="confirm-archive-button"
            data-qa="confirm-archive-button"
            phx-click="confirm_archive"
            phx-value-issue_id={@issue.id}
            class="px-3 py-1.5 rounded-lg bg-red-600 hover:bg-red-500 text-white text-xs font-semibold cursor-pointer shadow-xs"
          >
            Archive
          </button>
        </div>
      </div>
    </div>
    """
  end
end
