defmodule RailWeb.OverviewLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.CoreComponents,
    only: [
      dispatch_banner: 1,
      empty_state: 1,
      question_card: 1,
      role_roster: 1,
      with_agent_section: 1
    ]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Roles

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)
      |> assign(:current_project_id, nil)
      |> assign(:running_count, 0)
      |> assign(:waiting, [])
      |> assign(:with_agent, [])
      |> assign(:roster_groups, [])
      |> assign(:dispatch_disabled, check_dispatch_disabled())
      |> assign(:submitting, false)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)
      |> assign(:current_project_id, project_id)
      |> load_overview_state(project_id)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div id="overview-view" data-qa="overview-view" class="space-y-6">
        <!-- Header row: Overview in bold + running agents pill -->
        <div class="flex items-center space-x-3" id="overview-header" data-qa="overview-hero">
          <h1
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
            id="overview-title"
            data-qa="overview_title"
          >
            Overview
          </h1>
          <span
            id="running-agent-count-pill"
            data-qa="running_agent_count_pill"
            class="px-2.5 py-1 rounded-full text-xs font-semibold bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100"
          >
            {running_agents_label(@running_count)}
          </span>
        </div>

        <!-- Optional Dispatch-Disabled Banner -->
        <.dispatch_banner :if={@dispatch_disabled} visible={@dispatch_disabled} />

        <!-- Main Layout: 2 Columns (Main Queue on Left, Role Roster on Right) -->
        <div class="flex items-start gap-6">
          <!-- Main Queue Column -->
          <div class="flex-1 min-w-0" id="overview-main-queue">
            <!-- "WAITING ON YOU · {count}" Section -->
            <div :if={@waiting != []} id="waiting-on-you-section" class="mb-6">
              <h2
                id="waiting-header"
                data-qa="waiting-header"
                class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-3"
              >
                WAITING ON YOU · {length(@waiting)}
              </h2>

              <div class="space-y-3" id="waiting-blocks-list">
                <.question_card :for={run <- @waiting} run={run} submitting={@submitting} />
              </div>
            </div>

            <!-- "WITH AN AGENT · {count} · RECENTLY UPDATED" Section -->
            <.with_agent_section runs={@with_agent} />

            <!-- "All clear" Empty State (only when waiting and with_agent are both empty) -->
            <.empty_state :if={@waiting == [] and @with_agent == []} />
          </div>

          <!-- Role Roster Sidebar -->
          <.role_roster groups={@roster_groups} is_filtered={@current_project_id != nil} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("answer_question", %{"question_id" => question_id, "answer" => answer}, socket) do
    answer_one(question_id, answer)

    socket = load_overview_state(socket, socket.assigns[:current_project_id])
    {:noreply, socket}
  end

  def handle_event("dismiss_question", %{"question_id" => question_id}, socket) do
    dismiss_question(question_id)

    socket = load_overview_state(socket, socket.assigns[:current_project_id])
    {:noreply, socket}
  end

  def handle_event("send_answers", %{"run_id" => run_id}, socket) do
    with {:ok, run} <- Pipeline.get_run(run_id) do
      Pipeline.send_answers(run)
    end

    {:noreply, load_overview_state(socket, socket.assigns[:current_project_id])}
  end

  def handle_event("submit_question_answer", %{"question_id" => question_id, "answer" => answer}, socket) do
    case String.trim(answer) do
      "" ->
        {:noreply, socket}

      trimmed ->
        answer_one(question_id, trimmed)
        socket = load_overview_state(socket, socket.assigns[:current_project_id])
        {:noreply, socket}
    end
  end

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # The overview is a list of runs. What each one is doing it says itself, and the
  # questions it asked hang off it, so nothing here has to work out which run a
  # task means.
  defp load_overview_state(socket, project_id) do
    runs =
      Pipeline.list_runs(
        project_id: project_id,
        preload: [:role, :questions, task: [:project, :issue]]
      )

    socket
    |> assign(:waiting, runs |> Enum.filter(&Run.needs_attention?/1) |> Enum.sort_by(&Run.waiting_since/1, DateTime))
    |> assign(:with_agent, runs |> Enum.filter(&Run.running?/1) |> Enum.sort_by(& &1.started_at, {:desc, DateTime}))
    |> assign(:running_count, Enum.count(runs, &Run.running?/1))
    |> assign(:roster_groups, build_roster_groups(project_id, runs))
    |> assign(:dispatch_disabled, check_dispatch_disabled())
  end

  defp build_roster_groups(project_id, runs) when is_binary(project_id) do
    case Projects.get_project(project_id) do
      {:ok, project} -> [{project, role_entries(project, runs)}]
      _no_project -> []
    end
  end

  defp build_roster_groups(nil, runs) do
    Enum.map(Projects.list_projects(), fn project ->
      project_runs = Enum.filter(runs, &(&1.task.project_id == project.id))
      {project, role_entries(project, project_runs)}
    end)
  end

  defp role_entries(project, runs) do
    project.id
    |> Roles.list_roles()
    |> Enum.map(&build_role_entry(&1, runs))
  end

  # A role is busy on its own run — the one it is holding — and on nothing else.
  defp build_role_entry(role, runs) do
    active_run = Enum.find(runs, &(&1.role_id == role.id and Run.state(&1) in [:running, :blocked, :done]))
    waiting? = active_run != nil and Run.state(active_run) in [:blocked, :done]

    subtitle =
      cond do
        is_nil(active_run) -> "Idle"
        waiting? -> "Waiting on you · #{task_key(active_run.task)}"
        true -> "#{task_key(active_run.task)} · running"
      end

    %{role: role, active_run: active_run, waiting?: waiting?, subtitle: subtitle}
  end

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}), do: id

  defp check_dispatch_disabled, do: Application.get_env(:rail, :no_dispatch, false)

  # Answering records and nothing more: the agent hears the whole round when the
  # human presses Send answers.
  defp answer_one(question_id, answer) do
    with {:ok, question} <- Pipeline.get_question(question_id) do
      Pipeline.answer_question(question, answer)
    end
  end

  defp running_agents_label(1), do: "1 agent running"
  defp running_agents_label(n), do: "#{n} agents running"

  defp dismiss_question(question_id) do
    case Pipeline.get_question(question_id) do
      {:ok, question} -> Pipeline.dismiss_question(question)
      _not_found -> :ok
    end
  end
end
