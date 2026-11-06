defmodule RailWeb.Components.CyclePanel do
  @moduledoc """
  The cycle beside its issues: its dates and status, its progress in points with the burnup chart, and each assignee's
  share done. An assignee row raises `pick_owner`, and hovering a day of the chart swaps the figures for that day's.
  """
  use RailWeb, :html

  attr :cycle, :map, required: true
  # What `Rail.Issues.get_cycle_progress/2` read for it.
  attr :progress, :map, required: true
  attr :owner, :string, default: nil
  attr :today, :any, default: nil
  # With a project it is one block of a column of panels, whose header raises `toggle_cycle_panel`.
  attr :project, :map, default: nil
  attr :open, :boolean, default: true
  attr :id_prefix, :string, default: "cycle"

  def cycle_panel(%{open: false} = assigns) do
    assigns = assign_header(assigns)

    ~H"""
    <button
      type="button"
      id={"#{@id_prefix}-panel-toggle"}
      aria-expanded="false"
      phx-click="toggle_cycle_panel"
      phx-value-project_id={@project.id}
      class="w-full flex items-center gap-2.5 px-3 py-2.5 text-left cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800/60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      <.project_badge project={@project} />
      <span class="min-w-0 flex-1">
        <span class="block text-[13px] font-semibold text-slate-900 dark:text-slate-100 truncate">
          {@label}
        </span>
        <span
          id={"#{@id_prefix}-panel-dates"}
          class="block text-xs text-slate-500 dark:text-slate-400 truncate"
        >
          {@dates}
        </span>
      </span>
      <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400 whitespace-nowrap">
        <span class="font-semibold text-slate-700 dark:text-slate-200">
          {share(@progress.completed, @progress.scope)}
        </span>
        of {@progress.scope}
      </span>
      <.icon name="pi-caret-down" class="h-3.5 w-3.5 shrink-0 text-slate-500 dark:text-slate-400" />
    </button>
    """
  end

  def cycle_panel(%{project: nil} = assigns) do
    assigns = assign_header(assigns)

    ~H"""
    <aside
      id={"#{@id_prefix}-panel"}
      aria-label={@label}
      phx-hook="CycleFigures"
      data-cycle={@cycle.id}
      class="group/cycle w-full lg:w-[380px] shrink-0 lg:sticky lg:top-0 order-first lg:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4 space-y-5"
    >
      <div>
        <div class="flex items-center gap-2 flex-wrap">
          <.tag id={"#{@id_prefix}-panel-tag"} status={@cycle.status} />
          <span
            id={"#{@id_prefix}-panel-dates"}
            data-field="date"
            data-today={@dates}
            class="text-xs text-slate-500 dark:text-slate-400 group-data-[hovering]/cycle:font-semibold group-data-[hovering]/cycle:text-slate-800 dark:group-data-[hovering]/cycle:text-slate-100"
          >
            {@dates}
          </span>
        </div>
        <h2 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100 break-words">
          {@label}
        </h2>
      </div>
      <.details
        id_prefix={@id_prefix}
        cycle={@cycle}
        progress={@progress}
        owner={@owner}
        label={@label}
        today={@today}
      />
    </aside>
    """
  end

  def cycle_panel(assigns) do
    assigns = assign_header(assigns)

    ~H"""
    <section
      id={"#{@id_prefix}-panel"}
      aria-label={@label}
      phx-hook="CycleFigures"
      data-cycle={@cycle.id}
      class="group/cycle"
    >
      <button
        type="button"
        id={"#{@id_prefix}-panel-toggle"}
        aria-expanded="true"
        phx-click="toggle_cycle_panel"
        phx-value-project_id={@project.id}
        class="w-full flex items-center gap-2.5 px-3 pt-3 pb-1 text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
      >
        <.project_badge project={@project} />
        <.tag id={"#{@id_prefix}-panel-tag"} status={@cycle.status} />
        <span
          id={"#{@id_prefix}-panel-dates"}
          data-field="date"
          data-today={@dates}
          class="min-w-0 flex-1 text-xs text-slate-500 dark:text-slate-400 truncate group-data-[hovering]/cycle:font-semibold group-data-[hovering]/cycle:text-slate-800 dark:group-data-[hovering]/cycle:text-slate-100"
        >
          {@dates}
        </span>
        <.icon name="pi-caret-up" class="h-3.5 w-3.5 shrink-0 text-slate-500 dark:text-slate-400" />
      </button>
      <div class="px-3 pb-3 space-y-5">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100 break-words">{@label}</h2>
        <.details
          id_prefix={@id_prefix}
          cycle={@cycle}
          progress={@progress}
          owner={@owner}
          label={@label}
          today={@today}
        />
      </div>
    </section>
    """
  end

  attr :id_prefix, :string, required: true
  attr :cycle, :map, required: true
  attr :progress, :map, required: true
  attr :owner, :string, required: true
  attr :label, :string, required: true
  attr :today, :any, required: true

  defp details(assigns) do
    %{cycle: cycle, progress: progress} = assigns
    planned? = cycle.status == :upcoming
    show_chart = not planned? and cycle.scope_history != []
    charted = with_today(cycle, progress, assigns.today)

    assigns =
      assigns
      |> assign(:planned, planned?)
      |> assign(:scope_change, if(planned?, do: "", else: change_label(progress.scope_change)))
      |> assign(:show_chart, show_chart)
      |> assign(:charted, charted)
      |> assign(:days, if(show_chart, do: day_figures(charted, List.first(cycle.scope_history)), else: []))
      |> assign(:chart_starts, Calendar.strftime(cycle.starts_on, "%b %-d"))

    ~H"""
    <div id={"#{@id_prefix}-progress"} class="grid grid-cols-3 gap-4">
      <.figure
        id={"#{@id_prefix}-scope"}
        field="scope"
        name="Scope"
        color="#94a3b8"
        dashed
        points={@progress.scope}
      >
        <:change>
          <span
            data-field="scopeChange"
            data-today={@scope_change}
            class="text-xs font-medium text-slate-600 dark:text-slate-300"
          >
            {@scope_change}
          </span>
        </:change>
        <p :if={@planned} class="text-xs text-slate-500 dark:text-slate-400">Planned so far</p>
      </.figure>
      <.figure
        id={"#{@id_prefix}-started"}
        field="started"
        name="Started"
        color="#0d9488"
        points={@progress.started}
      >
        <p
          data-field="startedShare"
          data-today={share(@progress.started, @progress.scope)}
          class="text-xs text-slate-500 dark:text-slate-400"
        >
          {share(@progress.started, @progress.scope)}
        </p>
      </.figure>
      <.figure
        id={"#{@id_prefix}-completed"}
        field="completed"
        name="Completed"
        color="#6366f1"
        points={@progress.completed}
      >
        <p
          data-field="completedShare"
          data-today={share(@progress.completed, @progress.scope)}
          class="text-xs text-slate-500 dark:text-slate-400"
        >
          {share(@progress.completed, @progress.scope)}
        </p>
      </.figure>
    </div>

    <.cycle_chart
      :if={@show_chart}
      cycle={@charted}
      label={@label}
      today={@today}
      id_prefix={@id_prefix}
      days={@days}
    />
    <p
      :if={!@show_chart}
      id={"#{@id_prefix}-chart-pending"}
      class="text-xs text-slate-500 dark:text-slate-400"
    >
      The chart starts on {@chart_starts}.
    </p>

    <div :if={@progress.owners != []} id={"#{@id_prefix}-owners"} class="pt-1">
      <p class="text-xs font-semibold text-slate-500 dark:text-slate-400 mb-1.5">Assignees</p>
      <ul class="space-y-0.5">
        <li :for={owner <- @progress.owners}>
          <button
            type="button"
            id={"#{@id_prefix}-owner-#{owner.user.id}"}
            phx-click="pick_owner"
            phx-value-user_id={owner.user.id}
            aria-pressed={to_string(@owner == owner.user.id)}
            class={[
              "w-full flex items-center gap-2.5 h-9 px-2 rounded-lg text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
              if(@owner == owner.user.id,
                do:
                  "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-inset ring-blue-200 dark:ring-blue-800",
                else: "hover:bg-slate-100 dark:hover:bg-slate-800/60"
              ),
              @owner not in [nil, owner.user.id] && "opacity-60"
            ]}
          >
            <.assignee user={owner.user} />
            <span class="min-w-0 flex-1 truncate text-[13px] font-medium text-slate-900 dark:text-slate-100">
              {owner.user.name || owner.user.login}
            </span>
            <span
              :if={@owner == owner.user.id}
              class="text-xs font-semibold text-blue-700 dark:text-blue-300"
            >
              Clear filter
            </span>
            <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400 whitespace-nowrap">
              <span class="font-semibold text-slate-700 dark:text-slate-200">
                {share(owner.completed, owner.points)}
              </span>
              of {owner.points}
            </span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :status, :atom, required: true

  defp tag(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center h-5 px-2 rounded-full text-[11px] font-semibold shrink-0",
        if(@status == :ended,
          do: "bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200",
          else:
            "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-200 ring-1 ring-inset ring-blue-300 dark:ring-blue-800"
        )
      ]}
    >
      {tag_label(@status)}
    </span>
    """
  end

  attr :id, :string, required: true
  # What `CycleFigures` calls this figure, and `#{field}Unit` its unit.
  attr :field, :string, required: true
  attr :name, :string, required: true
  attr :color, :string, required: true
  attr :dashed, :boolean, default: false
  attr :points, :integer, required: true
  slot :change
  slot :inner_block

  # Each figure names its line's stroke beside it, so no line is told apart by color alone.
  defp figure(assigns) do
    ~H"""
    <div id={@id} class="min-w-0">
      <p class="flex items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400">
        <svg width="14" height="6" aria-hidden="true">
          <line
            x1="0"
            y1="3"
            x2="14"
            y2="3"
            stroke={@color}
            stroke-width="2"
            stroke-dasharray={@dashed && "3 2"}
          />
        </svg>
        {@name}
      </p>
      <p class="mt-1 flex items-baseline gap-1 whitespace-nowrap">
        <span
          data-field={@field}
          data-today={@points}
          class="text-lg font-semibold text-slate-900 dark:text-slate-100"
        >
          {@points}
        </span>
        <span
          data-field={"#{@field}Unit"}
          data-today={unit(@points)}
          class="text-xs font-medium text-slate-500 dark:text-slate-400"
        >
          {unit(@points)}
        </span>
        {render_slot(@change)}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp assign_header(%{cycle: cycle} = assigns) do
    today = assigns.today || Date.utc_today()

    assigns
    |> assign(:today, today)
    |> assign(:label, cycle.name || "Cycle #{cycle.number}")
    |> assign(:dates, dates(cycle, today))
  end

  defp tag_label(:running), do: "Current"
  defp tag_label(:upcoming), do: "Next"
  defp tag_label(:ended), do: "Ended"

  defp dates(cycle, today) do
    range = "#{Calendar.strftime(cycle.starts_on, "%b %-d")} – #{Calendar.strftime(cycle.ends_on, "%b %-d")}"

    case {cycle.status, Date.diff(cycle.ends_on, today), Date.diff(cycle.starts_on, today)} do
      {:running, 0, _starts} -> "#{range} · Last day"
      {:running, 1, _starts} -> "#{range} · 1 day left"
      {:running, left, _starts} -> "#{range} · #{left} days left"
      {:upcoming, _left, 1} -> "#{range} · starts tomorrow"
      {:upcoming, _left, starts} -> "#{range} · starts in #{starts} days"
      {:ended, _left, _starts} -> range
    end
  end

  # A running cycle's lines end on today at the panel's own figures, whatever Linear holds for the day.
  defp with_today(%{status: :running, scope_history: [_first | _later]} = cycle, progress, today) do
    index = Date.diff(today, cycle.starts_on)

    if index in 0..Date.diff(cycle.ends_on, cycle.starts_on) do
      %{
        cycle
        | scope_history: place_today(cycle.scope_history, index, progress.scope),
          started_history: place_today(cycle.started_history, index, progress.started),
          completed_history: place_today(cycle.completed_history, index, progress.completed)
      }
    else
      cycle
    end
  end

  defp with_today(cycle, _progress, _today), do: cycle

  defp place_today(values, index, figure) do
    recorded = Enum.take(values, index)
    Enum.concat([recorded, List.duplicate(List.last(values, 0), index - length(recorded)), [figure]])
  end

  # Every day the chart draws, ready to show on hover. `first` is Linear's, so today's change matches the panel's.
  defp day_figures(cycle, first) do
    total = Date.diff(cycle.ends_on, cycle.starts_on) + 1

    for {scope, index} <- cycle.scope_history |> Enum.take(total) |> Enum.with_index() do
      date = Date.add(cycle.starts_on, index)
      points = round(scope)
      started = round(Enum.at(cycle.started_history, index, 0))
      completed = round(Enum.at(cycle.completed_history, index, 0))

      %{
        "data-date" => "#{Calendar.strftime(date, "%a %b %-d")} · day #{index + 1} of #{total}",
        "data-scope" => points,
        "data-scope-unit" => unit(points),
        "data-scope-change" => scope_change(points, first),
        "data-started" => started,
        "data-started-unit" => unit(started),
        "data-started-share" => share(started, points),
        "data-completed" => completed,
        "data-completed-unit" => unit(completed),
        "data-completed-share" => share(completed, points)
      }
    end
  end

  # A cycle opening at 0 has no change to read, as `Rail.Issues.get_cycle_progress/2` says of today.
  defp scope_change(points, first) when first > 0, do: change_label(round((points - first) / first * 100))
  defp scope_change(_points, _first), do: ""

  defp change_label(nil), do: ""
  defp change_label(change) when change >= 0, do: "+#{change}%"
  defp change_label(change), do: "#{change}%"

  defp unit(1), do: "pt"
  defp unit(_points), do: "pts"

  defp share(_part, 0), do: "0%"
  defp share(part, whole), do: "#{round(part / whole * 100)}%"
end
