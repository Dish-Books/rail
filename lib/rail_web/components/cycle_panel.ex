defmodule RailWeb.Components.CyclePanel do
  @moduledoc """
  The cycle beside its issues: its dates and whether it is current, its progress in points with the burnup chart,
  and each owner's share done. An owner row raises `pick_owner`; the figures stay the whole cycle's.
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
      class="w-full lg:w-[340px] shrink-0 lg:sticky lg:top-0 order-first lg:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4 space-y-5"
    >
      <div>
        <div class="flex items-center gap-2 flex-wrap">
          <.tag id={"#{@id_prefix}-panel-tag"} status={@cycle.status} />
          <span id={"#{@id_prefix}-panel-dates"} class="text-xs text-slate-500 dark:text-slate-400">{@dates}</span>
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
    <section id={"#{@id_prefix}-panel"} aria-label={@label}>
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
          class="min-w-0 flex-1 text-xs text-slate-500 dark:text-slate-400 truncate"
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
    since = Calendar.strftime(assigns.cycle.starts_on, "%b %-d")

    assigns =
      assigns
      |> assign(:scope_note, scope_note(assigns.cycle.status, assigns.progress.scope_change, since))
      |> assign(:show_chart, assigns.cycle.status != :upcoming and assigns.cycle.scope_history != [])
      |> assign(:chart_starts, since)

    ~H"""
    <div id={"#{@id_prefix}-progress"} class="grid grid-cols-3 gap-4">
      <.figure id={"#{@id_prefix}-scope"} name="Scope" color="#94a3b8" dashed points={@progress.scope}>
        <p :if={@scope_note} class="text-xs text-slate-600 dark:text-slate-300">{@scope_note}</p>
      </.figure>
      <.figure id={"#{@id_prefix}-started"} name="Started" color="#0d9488" points={@progress.started}>
        <p class="text-xs text-slate-500 dark:text-slate-400">
          {share(@progress.started, @progress.scope)}
        </p>
      </.figure>
      <.figure
        id={"#{@id_prefix}-completed"}
        name="Completed"
        color="#6366f1"
        points={@progress.completed}
      >
        <p class="text-xs text-slate-500 dark:text-slate-400">
          {share(@progress.completed, @progress.scope)}
        </p>
      </.figure>
    </div>

    <.cycle_chart
      :if={@show_chart}
      cycle={@cycle}
      label={@label}
      today={@today}
      id_prefix={@id_prefix}
    />
    <p
      :if={!@show_chart}
      id={"#{@id_prefix}-chart-pending"}
      class="text-xs text-slate-500 dark:text-slate-400"
    >
      The chart starts on {@chart_starts}.
    </p>

    <div :if={@progress.owners != []} id={"#{@id_prefix}-owners"} class="pt-1">
      <p class="text-xs font-semibold text-slate-500 dark:text-slate-400 mb-1.5">Owners</p>
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
  attr :name, :string, required: true
  attr :color, :string, required: true
  attr :dashed, :boolean, default: false
  attr :points, :integer, required: true
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
        <span class="text-lg font-semibold text-slate-900 dark:text-slate-100">{@points}</span>
        <span class="text-xs font-medium text-slate-500 dark:text-slate-400">
          {if @points == 1, do: "pt", else: "pts"}
        </span>
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

  defp scope_note(:upcoming, _change, _since), do: "Planned so far"
  defp scope_note(_status, nil, _since), do: nil
  defp scope_note(_status, change, since) when change >= 0, do: "+#{change}% since #{since}"
  defp scope_note(_status, change, since), do: "#{change}% since #{since}"

  defp share(_part, 0), do: "0%"
  defp share(part, whole), do: "#{round(part / whole * 100)}%"
end
