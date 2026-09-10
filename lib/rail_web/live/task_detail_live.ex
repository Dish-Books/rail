defmodule RailWeb.TaskDetailLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Task")
      |> assign(:current_section, :tasks)
      |> assign(:task, nil)
      |> assign(:task_id, nil)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    task_id = Map.get(params, "id")

    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    task =
      if task_id && socket.assigns[:current_scope] do
        case Pipeline.get_task(socket.assigns.current_scope, task_id) do
          {:ok, t} -> t
          _other -> nil
        end
      end

    title = if task, do: task.title, else: "Task Detail"

    socket =
      socket
      |> assign(:page_title, title)
      |> assign(:current_section, :tasks)
      |> assign(:task_id, task_id)
      |> assign(:task, task)
      |> assign(:current_project_id, project_id)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="task-detail-view" data-qa="task-detail-view" class="space-y-6">
      <div class="flex items-center justify-between" id="task-detail-header">
        <h1
          class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)]"
          id="task-detail-title"
          data-qa="task_detail_title"
        >
          {if @task, do: @task.title, else: "Task Detail"}
        </h1>
      </div>

      <div class="m3-card p-6" id="task-detail-content">
        <div :if={@task} id="task-details-pane" class="space-y-3">
          <div class="text-sm font-semibold text-[var(--color-on-surface)]">
            Stage: <span class="font-mono text-indigo-600">{@task.stage}</span> ({@task.stage_state})
          </div>
          <p class="text-xs text-[var(--color-outline)]">
            {@task.description}
          </p>
        </div>

        <p :if={is_nil(@task)} class="text-sm text-[var(--color-outline)]" id="task-placeholder">
          Task detail shell for task <span class="font-mono text-[var(--color-primary)]">{@task_id}</span>.
        </p>
      </div>
    </div>
    """
  end
end
