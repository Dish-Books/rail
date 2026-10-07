defmodule RailWeb.OverviewLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.Utils.ChildStatus

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Scope
  alias Rail.Tools

  @throughput_days 30
  @activity_limit 8
  # Waiting on you, then broken, then working or in line to, then not started.
  @attention_rank %{done: 0, blocked: 0, failed: 1, stopped: 1, running: 2, waiting: 2, queued: 3}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
      Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    end

    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)

    {:ok, socket}
  end

  # Whose work is in the URL, so it can be linked to and survive a reload; the
  # project is the switcher's.
  def handle_params(params, _uri, socket) do
    everyone = params["everyone"] == "true"

    socket =
      socket
      |> assign(:view, if(everyone, do: :everyone, else: :mine))
      |> load_overview_state(socket.assigns.project_filter, everyone)

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
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div
        id="overview-view"
        data-qa="overview-view"
        class="grid gap-8 lg:grid-cols-[minmax(0,1fr)_320px]"
      >
        <div id="overview-main" class="min-w-0 space-y-8">
          <.segmented_control
            id="overview-view-filter"
            data-qa="overview-view-filter"
            option_id="overview-view"
            options={[mine: "My work", everyone: "Everyone"]}
            selected={@view}
            event="select_view"
            value_name="view"
            option_qa="overview-view-option"
          />

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
          <.sandbox_meters
            :if={@sandboxes.capacity}
            capacity={@sandboxes.capacity}
            running={@sandboxes.running}
            waiting={length(@sandboxes.waiting)}
            oldest_waiting={@stats.oldest_waiting_for_resources}
          />

          <.in_progress_tasks
            groups={@in_progress_groups}
            count={@stats.in_progress}
            is_filtered={@current_project_id != nil}
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

  def handle_event("select_view", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: overview_path(socket.assigns, everyone: view == "everyone"))}
  end

  # Every section comes from the one reload, so they never disagree; reassigning
  # without a patch keeps the view, the open switcher and the scroll where they were.
  def handle_info({:pipeline_changed, _task_id}, socket) do
    {:noreply, load_overview_state(socket, socket.assigns.project_filter, socket.assigns.view == :everyone)}
  end

  def handle_info(:sandboxes_changed, socket) do
    {:noreply, load_overview_state(socket, socket.assigns.project_filter, socket.assigns.view == :everyone)}
  end

  def handle_info({:issue_changed, _issue_id}, socket) do
    {:noreply, load_overview_state(socket, socket.assigns.project_filter, socket.assigns.view == :everyone)}
  end

  def handle_info({:issues_synced, _project_id}, socket) do
    {:noreply, load_overview_state(socket, socket.assigns.project_filter, socket.assigns.view == :everyone)}
  end

  # Neither moves a task.
  def handle_info({:issue_created, _issue_id}, socket), do: {:noreply, socket}
  def handle_info({:issue_comments_changed, _issue_id}, socket), do: {:noreply, socket}

  # The overview is the tasks in flight and the runs behind them; a task stands
  # where the latest run at its own stage left it.
  defp load_overview_state(socket, project_id, everyone) do
    now = DateTime.utc_now()
    user_id = socket.assigns.current_scope.user.id
    # A nil owner means no filter, so the own view must always name the user.
    owner_user_id = if everyone, do: nil, else: user_id
    preload = [:role, :questions, task: [:project, :issue, parent_task: :issue]]

    runs = Pipeline.list_runs(project_id: project_id, owner_user_id: owner_user_id, preload: preload)

    {tasks, children} = load_tasks(project_id, owner_user_id)

    # The stat and the list both read this one list, so they cannot disagree.
    in_progress =
      Enum.filter(tasks, &(is_nil(&1.merged_at) and &1.stage != :merged and is_nil(&1.issue.completed_at)))

    stage_runs = latest_stage_runs(runs)

    # A task waits on a human once, whatever its stage: the run of the stage it is
    # in is the one thing to do about it.
    waiting =
      stage_runs
      |> Map.values()
      |> Enum.filter(&Run.needs_attention?/1)
      |> Enum.sort_by(&Run.waiting_since/1, DateTime)

    # Waiting on you is the user's own in either view; Up next follows the view.
    waiting_on_user = Enum.filter(waiting, &(&1.task.issue.owner_user_id == user_id))

    # Shipped means Linear completed the issue. Sixty days covers this month's
    # count and the month it is compared with.
    %{issues: completed} =
      Issues.list_issues(
        project_id: project_id,
        owner_user_id: owner_user_id,
        show_finished: true,
        completed_after: DateTime.shift(now, day: -60)
      )

    sandboxes = load_sandboxes()

    socket
    |> assign(:waiting, waiting)
    |> assign(:sandboxes, sandboxes)
    |> assign(:stats, stats(in_progress, completed, waiting_on_user, sandboxes.waiting, now))
    |> assign(:activity, activity(runs, completed, splits(tasks, children), DateTime.shift(now, day: -1)))
    |> assign(:in_progress_groups, build_in_progress_groups(in_progress, stage_runs, children, user_id, now))
    |> assign(:throughput, throughput(completed, DateTime.to_date(now)))
    |> assign(:dispatch_disabled, Application.get_env(:rail, :no_dispatch, false))
    # The rail badge sits beside these stats, so it comes from the same reload.
    |> assign(:attention_count, Pipeline.count_attention(project_id: Scope.project_ids(socket.assigns.current_scope)))
  end

  # A split is one piece of work, so its children are read through their parent, which they are cleaned up with.
  defp load_tasks(project_id, owner_user_id) do
    preload = [:project, :issue, :implementation_plan, runs: [:role, :questions]]
    tasks = Pipeline.list_tasks(project_id: project_id, owner_user_id: owner_user_id, preload: preload)
    {children, tasks} = Enum.split_with(tasks, &is_binary(&1.parent_task_id))
    {tasks, Enum.group_by(children, & &1.parent_task_id)}
  end

  # An earlier run at the task's stage has been retried, and one at another stage
  # is behind it, so neither says where the task stands.
  defp latest_stage_runs(runs) do
    runs
    |> Enum.filter(&(&1.role.stage == &1.task.stage))
    |> Enum.group_by(& &1.task_id)
    |> Map.new(fn {task_id, task_runs} ->
      {task_id, Enum.max_by(task_runs, &(&1.started_at || &1.inserted_at), DateTime)}
    end)
  end

  # Defaults stay out of the URL, so the user's own work is still just /.
  defp overview_path(assigns, changes) do
    params =
      [everyone: assigns.view == :everyone]
      |> Keyword.merge(changes)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)

    case params do
      [] -> ~p"/"
      params -> ~p"/?#{params}"
    end
  end

  # The machine is shared, so what waits for it is counted whichever project is picked.
  defp load_sandboxes do
    %{
      capacity:
        case Tools.get_sandbox_capacity() do
          {:ok, capacity} -> capacity
          _unknown -> nil
        end,
      running: Tools.list_os_processes(status: [:starting, :running], sandboxed: true),
      waiting: Tools.list_os_processes(status: [:waiting_for_resources], order: :queue)
    }
  end

  defp stats(in_progress, completed, waiting, waiting_for_resources, now) do
    shipped = shipped_between(completed, DateTime.shift(now, day: -30), now)
    prior = shipped_between(completed, DateTime.shift(now, day: -60), DateTime.shift(now, day: -30))

    %{
      in_progress: length(in_progress),
      shipped: shipped,
      shipped_delta: shipped - prior,
      waiting: length(waiting),
      oldest_waiting: oldest_waiting(waiting, now),
      waiting_for_resources: length(waiting_for_resources),
      oldest_waiting_for_resources: oldest_in_line(waiting_for_resources, now)
    }
  end

  defp shipped_between(completed, from, to) do
    Enum.count(completed, &(not DateTime.before?(&1.completed_at, from) and DateTime.before?(&1.completed_at, to)))
  end

  defp oldest_waiting([], _now), do: nil
  defp oldest_waiting([oldest | _rest], now), do: format_age(DateTime.diff(now, Run.waiting_since(oldest)))

  defp oldest_in_line([], _now), do: nil
  defp oldest_in_line([oldest | _rest], now), do: format_age(DateTime.diff(now, oldest.queued_at))

  defp throughput(completed, today) do
    shipped_on = Enum.frequencies_by(completed, &DateTime.to_date(&1.completed_at))

    today
    |> Date.add(1 - @throughput_days)
    |> Date.range(today)
    |> Enum.map(&%{date: &1, count: Map.get(shipped_on, &1, 0)})
  end

  # Every run says when it started and, once it is not working, how it ended; an
  # issue says when it shipped. The feed is those moments, newest first.
  defp activity(runs, completed, splits, since) do
    shipped =
      for issue <- completed do
        %{id: "shipped-#{issue.id}", at: issue.completed_at, actor: nil, text: "#{issue.identifier} shipped"}
      end

    runs
    |> Enum.flat_map(&run_activity/1)
    |> Enum.concat(shipped)
    |> Enum.concat(splits)
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
        :waiting -> nil
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
    if run.role.stage in [:plan, :engineer],
      do: "says #{key} is ready for review",
      else: "finished on #{key}"
  end

  defp questions(%Run{questions: [_one]}), do: "a question"
  defp questions(%Run{questions: questions}), do: "#{length(questions)} questions"

  # A split is split when its plan was approved, which is when its children were made.
  defp splits(tasks, children) do
    for %{implementation_plan: %{captured_at: at}} = task <- tasks, split = children[task.id] do
      %{id: "split-#{task.id}", at: at, actor: nil, text: "#{task.issue.identifier} split into #{length(split)}"}
    end
  end

  defp build_in_progress_groups(in_progress, stage_runs, children, user_id, now) do
    in_progress
    |> Enum.map(fn task ->
      case children[task.id] do
        split when is_list(split) -> build_split_entry(task, split, user_id, now)
        nil -> build_in_progress_entry(task, Map.get(stage_runs, task.id), user_id, now)
      end
    end)
    |> Enum.sort_by(& &1.changed_at, DateTime)
    |> Enum.sort_by(&Map.fetch!(@attention_rank, &1.state))
    |> Enum.group_by(& &1.task.project)
    |> Enum.sort_by(fn {project, _entries} -> project.inserted_at end, DateTime)
    |> Enum.sort_by(fn {project, _entries} -> project.name end)
  end

  defp build_in_progress_entry(task, run, user_id, now) do
    state = Run.state(run)

    changed_at =
      case state do
        :running -> run.started_at || run.inserted_at
        :waiting -> run.updated_at
        :queued -> task.updated_at
        _ended -> Run.waiting_since(run)
      end

    %{
      task: task,
      state: state,
      label: stage_label(task, run),
      style: run_state_style(run),
      # Amber means waiting on the viewer, the same work the Waiting on you stat counts.
      is_waiting: state in [:done, :blocked] and task.issue.owner_user_id == user_id,
      changed_at: changed_at,
      age: format_age(DateTime.diff(now, changed_at))
    }
  end

  # A split parent waits on the viewer when any of its children does, and stands as long as its oldest child.
  defp build_split_entry(task, children, user_id, now) do
    statuses = Enum.map(children, &child_status(&1, children))
    waiting = Enum.count(statuses, & &1.needs_attention)
    is_waiting = waiting > 0 and task.issue.owner_user_id == user_id

    # "You" and amber are for the split's owner; anyone else is told it needs attention.
    label =
      cond do
        is_waiting -> "#{waiting} need you"
        waiting > 0 -> "#{waiting} need attention"
        true -> "Plan approved"
      end

    %{
      task: task,
      state: if(waiting > 0, do: :done, else: :running),
      label: label,
      style: %{
        icon: "pi-arrows-split",
        text_class: if(is_waiting, do: "text-amber-700 dark:text-amber-300", else: "text-slate-500 dark:text-slate-400")
      },
      is_waiting: is_waiting,
      changed_at: task.updated_at,
      age: format_age(DateTime.diff(now, task.updated_at)),
      children: statuses
    }
  end
end
