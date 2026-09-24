defmodule RailWeb.OverviewLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Roles

  @throughput_days 30
  @activity_limit 8

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, load_overview_state(socket, socket.assigns.current_project_id)}
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
      <div
        id="overview-view"
        data-qa="overview-view"
        class="grid gap-8 lg:grid-cols-[minmax(0,1fr)_320px]"
      >
        <div id="overview-main" class="min-w-0 space-y-8">
          <.dispatch_banner :if={@dispatch_disabled} visible={@dispatch_disabled} />

          <.overview_stats stats={@stats} />

          <section id="up-next-section">
            <h2 class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
              Up next
            </h2>
            <.up_next runs={@waiting} />
          </section>

          <section id="since-yesterday-section">
            <h2 class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
              Since yesterday
            </h2>
            <.activity_feed entries={@activity} />
          </section>
        </div>

        <aside
          id="overview-sidebar"
          class="space-y-8 lg:border-l lg:border-slate-200 lg:dark:border-slate-700/70 lg:pl-8"
        >
          <.role_roster
            groups={@roster_groups}
            is_filtered={@current_project_id != nil}
            running_count={@running_count}
            role_count={@roster_groups |> Enum.map(&length(elem(&1, 1))) |> Enum.sum()}
          />

          <section id="throughput-section">
            <h2 class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
              Throughput
            </h2>
            <.throughput_chart days={@throughput} />
          </section>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # The overview is a list of runs and the tasks they belong to. What each run is
  # doing it says itself, so nothing here has to work out which run a task means.
  defp load_overview_state(socket, project_id) do
    now = DateTime.utc_now()

    runs = Pipeline.list_runs(project_id: project_id, preload: [:role, :questions, task: [:project, :issue]])
    tasks = Pipeline.list_tasks(project_id: project_id, preload: [:issue])
    # A task waits on a human once, whatever its stage: the run of the stage it is
    # in is the one thing to do about it.
    waiting =
      runs
      |> Enum.filter(&Run.needs_attention?/1)
      |> Enum.sort_by(&Run.waiting_since/1, DateTime)
      |> Enum.uniq_by(& &1.task_id)

    # Shipped means Linear completed the issue. Sixty days covers this month's
    # count and the month it is compared with.
    %{issues: completed} =
      Issues.list_issues(project_id: project_id, show_finished: true, completed_after: DateTime.shift(now, day: -60))

    socket
    |> assign(:waiting, waiting)
    |> assign(:stats, stats(tasks, completed, waiting, now))
    |> assign(:activity, activity(runs, completed, DateTime.shift(now, day: -1)))
    |> assign(:running_count, Enum.count(runs, &Run.running?/1))
    |> assign(:roster_groups, build_roster_groups(project_id, runs, now))
    |> assign(:throughput, throughput(completed, DateTime.to_date(now)))
    |> assign(:dispatch_disabled, Application.get_env(:rail, :no_dispatch, false))
  end

  defp stats(tasks, completed, waiting, now) do
    shipped = shipped_between(completed, DateTime.shift(now, day: -30), now)
    prior = shipped_between(completed, DateTime.shift(now, day: -60), DateTime.shift(now, day: -30))

    %{
      in_progress: Enum.count(tasks, &(is_nil(&1.merged_at) and &1.stage != :merged and is_nil(&1.issue.completed_at))),
      shipped: shipped,
      shipped_delta: shipped - prior,
      waiting: length(waiting),
      oldest_waiting: oldest_waiting(waiting, now)
    }
  end

  defp shipped_between(completed, from, to) do
    Enum.count(completed, &(not DateTime.before?(&1.completed_at, from) and DateTime.before?(&1.completed_at, to)))
  end

  defp oldest_waiting([], _now), do: nil
  defp oldest_waiting([oldest | _rest], now), do: format_age(DateTime.diff(now, Run.waiting_since(oldest)))

  defp throughput(completed, today) do
    shipped_on = Enum.frequencies_by(completed, &DateTime.to_date(&1.completed_at))

    today
    |> Date.add(1 - @throughput_days)
    |> Date.range(today)
    |> Enum.map(&%{date: &1, count: Map.get(shipped_on, &1, 0)})
  end

  # Every run says when it started and, once it is not working, how it ended; an
  # issue says when it shipped. The feed is those moments, newest first.
  defp activity(runs, completed, since) do
    shipped =
      for issue <- completed do
        %{id: "shipped-#{issue.id}", at: issue.completed_at, actor: nil, text: "#{issue.identifier} shipped"}
      end

    runs
    |> Enum.flat_map(&run_activity/1)
    |> Enum.concat(shipped)
    |> Enum.filter(&DateTime.after?(&1.at, since))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(@activity_limit)
  end

  defp run_activity(%Run{} = run) do
    key = run.task.issue.identifier
    entry = &%{id: "#{&1}-#{run.id}", at: &2, actor: run.role.name, text: &3}

    ended =
      case Run.state(run) do
        :running -> nil
        :blocked -> entry.("asked", Run.waiting_since(run), "asked #{questions(run)} on #{key}")
        :done -> entry.("ended", Run.waiting_since(run), done_text(run, key))
        :failed -> entry.("ended", Run.waiting_since(run), "failed on #{key}")
        :stopped -> entry.("ended", Run.waiting_since(run), "stopped on #{key}")
      end

    Enum.reject([entry.("started", run.started_at, "started on #{key}"), ended], &is_nil/1)
  end

  # A run at a stage a human signs off has handed its work over when it is done,
  # whether or not the human has since reviewed it and moved the task on.
  defp done_text(run, key) do
    if run.role.stage in [:product, :design, :architect, :engineer],
      do: "says #{key} is ready for review",
      else: "finished on #{key}"
  end

  defp questions(%Run{questions: [_one]}), do: "a question"
  defp questions(%Run{questions: questions}), do: "#{length(questions)} questions"

  defp build_roster_groups(project_id, runs, now) when is_binary(project_id) do
    case Projects.get_project(project_id) do
      {:ok, project} -> [{project, role_entries(project, runs, now)}]
      _no_project -> []
    end
  end

  defp build_roster_groups(nil, runs, now) do
    Enum.map(Projects.list_projects(), fn project ->
      project_runs = Enum.filter(runs, &(&1.task.project_id == project.id))
      {project, role_entries(project, project_runs, now)}
    end)
  end

  defp role_entries(project, runs, now) do
    project.id
    |> Roles.list_roles()
    |> Enum.map(fn role -> build_role_entry(role, Enum.filter(runs, &(&1.role_id == role.id)), now) end)
  end

  # A role reads off its own runs: one waiting on a human comes first, then one
  # working, then whichever it touched last.
  defp build_role_entry(role, runs, now) do
    waiting = Enum.find(runs, &Run.needs_attention?/1)
    running = Enum.find(runs, &Run.running?/1)
    last = Enum.max_by(runs, &Run.waiting_since/1, DateTime, fn -> nil end)

    {tone, run, subtitle} =
      cond do
        waiting -> waiting_entry(waiting, now)
        running -> {:running, running, "Running · #{running.task.issue.identifier}"}
        last -> last_subtitle(last, now)
        true -> {:idle, nil, "Idle · no work assigned"}
      end

    %{role: role, tone: tone, run: run, subtitle: subtitle}
  end

  # A role waiting because it broke still reads as broken: "waiting on you" is
  # true of it but says nothing about what it wants.
  defp waiting_entry(run, now) do
    key = run.task.issue.identifier

    case Run.state(run) do
      :done -> {:waiting, run, "Handed off #{key} · waiting on you"}
      :blocked -> {:waiting, run, "Blocked · #{key} · waiting on you"}
      :failed -> last_subtitle(run, now)
      :stopped -> {:failed, run, "Stopped #{age(run, now)} ago · #{key}"}
    end
  end

  defp age(run, now), do: format_age(DateTime.diff(now, Run.waiting_since(run)))

  defp last_subtitle(run, now) do
    key = run.task.issue.identifier

    if Run.state(run) == :failed,
      do: {:failed, run, "Failed #{age(run, now)} ago · #{key}"},
      else: {:idle, run, "Last ran #{age(run, now)} ago · #{key}"}
  end
end
