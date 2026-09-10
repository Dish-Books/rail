defmodule RailWeb.Components.IssueEditorModal do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Issues.Schemas.Issue

  attr :issue, :map, default: nil
  attr :visible, :boolean, default: false

  def issue_editor_modal(assigns) do
    ~H"""
    <div
      :if={@visible and @issue != nil}
      id="issue-editor-dialog"
      data-qa="issue-editor-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <div class="w-full max-w-2xl rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4">
        <!-- Modal Header -->
        <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-3">
          <div class="flex items-center gap-2">
            <h2
              class="text-base font-semibold text-slate-900 dark:text-slate-100"
              id="editor-dialog-title"
            >
              Edit {@issue.identifier}
            </h2>
            <a
              :if={@issue.url != nil and @issue.url != ""}
              href={@issue.url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-xs text-blue-600 dark:text-blue-500 hover:underline"
            >
              <span>Linear</span>
              <.icon name="pi-arrow-square-out" class="h-3.5 w-3.5" />
            </a>
          </div>

          <button
            type="button"
            id="close-editor-button"
            data-qa="close-editor-button"
            phx-click="close_editor"
            class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 text-sm font-bold p-1 cursor-pointer"
          >
            ✕
          </button>
        </div>

        <!-- Editor Form -->
        <form
          id="issue-editor-form"
          phx-change="editor_change"
          phx-submit="save_issue"
          class="space-y-4"
        >
          <input type="hidden" name="issue_id" value={@issue.id} />

          <div>
            <label
              for="editor-title-input"
              class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
            >
              Title
            </label>
            <input
              type="text"
              name="title"
              id="editor-title-input"
              data-qa="editor-title-input"
              value={@issue.title}
              required
              class="w-full px-3 py-2 text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
            />
          </div>

          <div>
            <label
              for="editor-description-input"
              class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
            >
              Description (Markdown issue body)
            </label>
            <textarea
              name="description"
              id="editor-description-input"
              data-qa="editor-description-input"
              rows="6"
              class="w-full px-3 py-2 text-xs rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500 font-mono"
            >{@issue.description}</textarea>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label
                for="editor-priority-select"
                class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
              >
                Priority
              </label>
              <select
                name="priority"
                id="editor-priority-select"
                data-qa="editor-priority-select"
                class="w-full px-3 py-2 text-xs rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
              >
                <%= for p <- Issue.priorities() do %>
                  <option value={to_string(p)} selected={to_string(@issue.priority) == to_string(p)}>
                    {Issue.priority_label(p)}
                  </option>
                <% end %>
              </select>
            </div>

            <div>
              <label
                for="editor-state-select"
                class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
              >
                State
              </label>
              <select
                name="state"
                id="editor-state-select"
                data-qa="editor-state-select"
                class="w-full px-3 py-2 text-xs rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
              >
                <%= for s <- Issue.states() do %>
                  <option value={to_string(s)} selected={to_string(@issue.state) == to_string(s)}>
                    {Issue.state_label(s)}
                  </option>
                <% end %>
              </select>
            </div>
          </div>

          <!-- Modal Footer -->
          <div class="flex items-center justify-between pt-4 border-t border-slate-200 dark:border-slate-700">
            <button
              type="button"
              id="editor-archive-button"
              data-qa="editor-archive-button"
              phx-click="open_archive"
              phx-value-issue_id={@issue.id}
              class="px-3 py-1.5 rounded-lg border border-red-500/30 text-red-500 hover:bg-red-500/10 text-xs font-semibold cursor-pointer"
            >
              Archive Issue
            </button>

            <div class="flex items-center gap-3">
              <button
                type="button"
                id="editor-cancel-button"
                data-qa="editor-cancel-button"
                phx-click="close_editor"
                class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
              >
                Cancel
              </button>

              <button
                type="submit"
                id="editor-save-button"
                data-qa="editor-save-button"
                class="px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 cursor-pointer shadow-xs"
              >
                Save Changes
              </button>
            </div>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
