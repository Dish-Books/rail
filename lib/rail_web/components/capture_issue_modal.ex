defmodule RailWeb.Components.CaptureIssueModal do
  @moduledoc false
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  attr :visible, :boolean, default: false
  attr :show_new_issue_modal, :boolean, default: nil
  attr :projects, :list, default: []
  attr :current_project_id, :string, default: nil
  attr :capture_ask, :string, default: ""
  attr :capture_project_id, :string, default: nil
  attr :capture_priority, :any, default: :medium
  attr :capture_error, :string, default: nil
  attr :capture_submitting, :boolean, default: false

  def capture_issue_modal(assigns) do
    is_open =
      if is_nil(assigns[:show_new_issue_modal]),
        do: assigns.visible,
        else: assigns.show_new_issue_modal

    active_projects = Enum.filter(assigns.projects, & &1.active)

    effective_project_id =
      cond do
        assigns.capture_project_id &&
            Enum.any?(active_projects, &(&1.id == assigns.capture_project_id)) ->
          assigns.capture_project_id

        assigns.current_project_id &&
            Enum.any?(active_projects, &(&1.id == assigns.current_project_id)) ->
          assigns.current_project_id

        active_projects != [] ->
          hd(active_projects).id

        true ->
          nil
      end

    can_submit =
      String.trim(assigns.capture_ask || "") != "" and not assigns.capture_submitting

    assigns =
      assigns
      |> assign(:is_open, is_open)
      |> assign(:active_projects, active_projects)
      |> assign(:effective_project_id, effective_project_id)
      |> assign(:can_submit, can_submit)

    ~H"""
    <div
      :if={@is_open}
      id="capture-idea-dialog"
      data-qa="capture_idea_dialog"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <div
        id="new-issue-modal"
        data-qa="capture_dialog"
        class="w-full max-w-lg rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4"
      >
        <!-- Modal Header -->
        <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-3">
          <h2
            class="text-base font-semibold text-slate-900 dark:text-slate-100"
            id="modal-headline"
            data-qa="capture_modal_title"
          >
            <span id="capture-modal-title">New Issue</span>
          </h2>
          <button
            type="button"
            id="close-new-issue-button"
            data-qa="close_new_issue_button"
            phx-click="close_new_issue"
            class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 text-sm font-bold p-1 cursor-pointer"
          >
            ✕
          </button>
        </div>

        <!-- Capture Form -->
        <form
          id="capture-issue-form"
          phx-change="capture_form_change"
          phx-submit="capture_form_submit"
          class="space-y-4"
        >
          <!-- Project Dropdown -->
          <div>
            <label
              for="capture-project-dropdown"
              class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
            >
              Project
            </label>
            <select
              id="capture-project-dropdown"
              name="project_id"
              data-qa="capture_project_dropdown"
              class="w-full px-3 py-2 text-xs rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
            >
              <%= for project <- @active_projects do %>
                <option
                  value={project.id}
                  selected={project.id == @effective_project_id}
                >
                  {project_label(project)}
                </option>
              <% end %>
            </select>
          </div>

          <!-- Single Multiline Ask Input -->
          <div>
            <label
              for="capture-idea-input"
              class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
            >
              Ask / Idea
            </label>
            <textarea
              id="capture-idea-input"
              name="ask"
              data-qa="capture_idea_input"
              rows="3"
              autofocus
              placeholder="What's the idea?"
              class="w-full min-h-[90px] px-3 py-2 text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
            >{@capture_ask}</textarea>
          </div>

          <!-- Priority Dropdown -->
          <div>
            <label
              for="capture-priority-dropdown"
              class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
            >
              Priority
            </label>
            <select
              id="capture-priority-dropdown"
              name="priority"
              data-qa="capture_priority_dropdown"
              class="w-full px-3 py-2 text-xs rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
            >
              <%= for p <- Issue.priorities() do %>
                <option
                  value={to_string(p)}
                  selected={to_string(@capture_priority) == to_string(p)}
                >
                  {Issue.priority_label(p)}
                </option>
              <% end %>
            </select>
          </div>

          <!-- Error Banner -->
          <div
            :if={@capture_error != nil and @capture_error != ""}
            id="capture-error-banner"
            data-qa="capture_error_banner"
            class="p-2.5 rounded-lg bg-red-500/10 border border-red-500/20 text-red-500 text-xs font-medium"
          >
            {@capture_error}
          </div>

          <!-- Modal Footer Actions -->
          <div class="flex items-center justify-end gap-3 pt-3 border-t border-slate-200 dark:border-slate-700">
            <button
              type="button"
              id="capture-cancel-button"
              data-qa="capture_cancel_button"
              phx-click="close_new_issue"
              class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
            >
              Cancel
            </button>

            <button
              type="submit"
              id="capture-submit-button"
              data-qa="capture_submit_button"
              disabled={not @can_submit}
              class={[
                "px-3 py-1.5 rounded-lg text-xs font-semibold shadow-xs transition-opacity",
                not @can_submit &&
                  "bg-slate-500 dark:bg-slate-400 text-white dark:text-slate-900 opacity-50 cursor-not-allowed",
                @can_submit &&
                  "bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer"
              ]}
            >
              {if @capture_submitting, do: "Adding...", else: "Add to Backlog (⌘Enter)"}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp project_label(project) do
    if project.linear_team_key && project.linear_team_key != "" do
      "#{project.name} (#{project.linear_team_key})"
    else
      project.name
    end
  end
end
