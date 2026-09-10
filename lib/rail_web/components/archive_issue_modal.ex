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
      <div class="w-full max-w-md rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4">
        <h2 class="text-base font-semibold text-[var(--color-on-surface)]" id="archive-modal-title">
          Archive {@issue.identifier}?
        </h2>

        <p class="text-xs text-[var(--color-outline)]" id="archive-modal-body">
          This archives "{@issue.title}" and marks it as canceled in Linear.
        </p>

        <div class="flex justify-end space-x-3 pt-3">
          <button
            type="button"
            id="cancel-archive-button"
            data-qa="cancel-archive-button"
            phx-click="close_archive"
            class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
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
