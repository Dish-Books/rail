defmodule RailWeb.Components.CaptureIssueModal do
  @moduledoc """
  The New Issue dialog. It keeps its own open state and form, so the page it
  sits on only hands it the projects.

  Anything on the page opens it with `open/0`, which targets the component by
  its DOM id.
  """
  use RailWeb, :live_component

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  @id "capture-issue"

  @doc """
  The component's DOM id, for mounting it once per page.
  """
  def id, do: @id

  @doc """
  A `phx-click` that opens the dialog from anywhere on the page.
  """
  def open(js \\ %JS{}), do: JS.push(js, "open", target: "##{@id}")

  def mount(socket) do
    socket = socket |> assign(:open, false) |> reset_form(nil)
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:current_scope, assigns[:current_scope])
      |> assign(:projects, assigns[:projects] || [])
      |> assign(:current_project_id, assigns[:current_project_id])

    {:ok, socket}
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:active_projects, Enum.filter(assigns.projects, & &1.active))
      |> assign(:can_submit, String.trim(assigns.title) != "")

    ~H"""
    <div id={id()} class="contents">
      <div
        :if={@open}
        id="capture-idea-dialog"
        data-qa="capture_idea_dialog"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      >
        <div
          id="new-issue-modal"
          data-qa="capture_dialog"
          class="w-full max-w-lg rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4"
        >
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
              phx-click="close"
              phx-target={@myself}
              class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 text-sm font-bold p-1 cursor-pointer"
            >
              ✕
            </button>
          </div>

          <form
            id="capture-issue-form"
            phx-change="change"
            phx-submit="submit"
            phx-target={@myself}
            class="space-y-4"
          >
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
                <option
                  :for={project <- @active_projects}
                  value={project.id}
                  selected={project.id == @project_id}
                >
                  {project_label(project)}
                </option>
              </select>
            </div>

            <div>
              <label
                for="capture-title-input"
                class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
              >
                Title
              </label>
              <input
                type="text"
                id="capture-title-input"
                name="title"
                value={@title}
                data-qa="capture_title_input"
                autofocus
                placeholder="What needs doing?"
                class="w-full px-3 py-2 text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
              />
            </div>

            <div>
              <label
                for="capture-description-input"
                class="block text-xs font-semibold text-slate-900 dark:text-slate-100 mb-1"
              >
                Description
              </label>
              <textarea
                id="capture-description-input"
                name="description"
                data-qa="capture_description_input"
                rows="3"
                placeholder="Details, context, acceptance criteria"
                class="w-full min-h-[90px] px-3 py-2 text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
              >{@description}</textarea>
            </div>

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
                <option :for={p <- Issue.priorities()} value={p} selected={@priority == p}>
                  {Issue.priority_label(p)}
                </option>
              </select>
            </div>

            <div
              :if={@error}
              id="capture-error-banner"
              data-qa="capture_error_banner"
              class="p-2.5 rounded-lg bg-red-500/10 border border-red-500/20 text-red-500 text-xs font-medium"
            >
              {@error}
            </div>

            <div class="flex items-center justify-end gap-3 pt-3 border-t border-slate-200 dark:border-slate-700">
              <button
                type="button"
                id="capture-cancel-button"
                data-qa="capture_cancel_button"
                phx-click="close"
                phx-target={@myself}
                class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
              >
                Cancel
              </button>

              <button
                type="submit"
                id="capture-submit-button"
                data-qa="capture_submit_button"
                disabled={not @can_submit}
                phx-disable-with="Adding..."
                class={[
                  "px-3 py-1.5 rounded-lg text-xs font-semibold shadow-xs transition-opacity",
                  not @can_submit &&
                    "bg-slate-500 dark:bg-slate-400 text-white dark:text-slate-900 opacity-50 cursor-not-allowed",
                  @can_submit &&
                    "bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer"
                ]}
              >
                Add to Triage (⌘Enter)
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("open", _params, socket) do
    socket =
      socket
      |> assign(:open, true)
      |> reset_form(default_project_id(socket.assigns.projects, socket.assigns.current_project_id))

    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    socket = socket |> assign(:open, false) |> reset_form(nil)
    {:noreply, socket}
  end

  def handle_event("change", params, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("submit", params, socket) do
    socket = assign_form(socket, params)
    %{title: title, description: description, priority: priority, project_id: project_id} = socket.assigns

    with false <- String.trim(title) == "",
         %{} = project <- Enum.find(socket.assigns.projects, &(&1.id == project_id)) do
      case Issues.create_issue(socket.assigns.current_scope, project, %{
             title: title,
             description: description,
             priority: priority
           }) do
        {:ok, _issue} -> {:noreply, close(socket)}
        {:error, reason} -> {:noreply, assign(socket, :error, error_message(reason))}
      end
    else
      true -> {:noreply, socket}
      nil -> {:noreply, assign(socket, :error, "Project not found")}
    end
  end

  defp close(socket), do: socket |> assign(:open, false) |> reset_form(nil)

  defp assign_form(socket, params) do
    socket
    |> assign(:title, params["title"] || "")
    |> assign(:description, params["description"] || "")
    |> assign(:project_id, params["project_id"])
    |> assign(:priority, Enum.find(Issue.priorities(), :medium, &(to_string(&1) == params["priority"])))
  end

  defp reset_form(socket, project_id) do
    socket
    |> assign(:title, "")
    |> assign(:description, "")
    |> assign(:project_id, project_id)
    |> assign(:priority, :medium)
    |> assign(:error, nil)
  end

  defp default_project_id(projects, current_project_id) do
    active_projects = Enum.filter(projects, & &1.active)

    if Enum.any?(active_projects, &(&1.id == current_project_id)),
      do: current_project_id,
      else: active_projects |> List.first(%{}) |> Map.get(:id)
  end

  defp project_label(%{linear_team_key: key, name: name}), do: "#{name} (#{key})"

  defp error_message(%Ecto.Changeset{}), do: "Could not create the issue"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
