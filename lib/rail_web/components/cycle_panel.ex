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

  def cycle_panel(assigns) do
    %{cycle: cycle, progress: progress} = assigns
    today = assigns.today || Date.utc_today()
    label = cycle.name || "Cycle #{cycle.number}"
    since = Calendar.strftime(cycle.starts_on, "%b %-d")

    assigns =
      assigns
      |> assign(:today, today)
      |> assign(:label, label)
      |> assign(:tag, tag(cycle.status))
      |> assign(:dates, dates(cycle, today))
      |> assign(:scope_note, scope_note(cycle.status, progress.scope_change, since))
      |> assign(:show_chart, cycle.status != :upcoming and cycle.scope_history != [])
      |> assign(:chart_starts, since)

    ~H"""
    <aside
      id="cycle-panel"
      aria-label={@label}
      class="w-full lg:w-[340px] shrink-0 lg:sticky lg:top-0 order-first lg:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4 space-y-5"
    >
      <div>
        <div class="flex items-center gap-2 flex-wrap">
          <span
            id="cycle-panel-tag"
            class={[
              "inline-flex items-center h-5 px-2 rounded-full text-[11px] font-semibold",
              if(@cycle.status == :ended,
                do: "bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200",
                else:
                  "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-200 ring-1 ring-inset ring-blue-300 dark:ring-blue-800"
              )
            ]}
          >
            {@tag}
          </span>
          <span id="cycle-panel-dates" class="text-xs text-slate-500 dark:text-slate-400">{@dates}</span>
        </div>
        <h2 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100 break-words">
          {@label}
        </h2>
      </div>

      <div id="cycle-progress" class="grid grid-cols-3 gap-4">
        <.figure id="cycle-scope" name="Scope" color="#94a3b8" dashed points={@progress.scope}>
          <p :if={@scope_note} class="text-xs text-slate-600 dark:text-slate-300">{@scope_note}</p>
        </.figure>
        <.figure id="cycle-started" name="Started" color="#0d9488" points={@progress.started}>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            {share(@progress.started, @progress.scope)}
          </p>
        </.figure>
        <.figure id="cycle-completed" name="Completed" color="#6366f1" points={@progress.completed}>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            {share(@progress.completed, @progress.scope)}
          </p>
        </.figure>
      </div>

      <.cycle_chart :if={@show_chart} cycle={@cycle} label={@label} today={@today} />
      <p
        :if={!@show_chart}
        id="cycle-chart-pending"
        class="text-xs text-slate-500 dark:text-slate-400"
      >
        The chart starts on {@chart_starts}.
      </p>

      <div :if={@progress.owners != []} id="cycle-owners" class="pt-1">
        <p class="text-xs font-semibold text-slate-500 dark:text-slate-400 mb-1.5">Owners</p>
        <ul class="space-y-0.5">
          <li :for={owner <- @progress.owners}>
            <button
              type="button"
              id={"cycle-owner-#{owner.user.id}"}
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
    </aside>
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

  defp tag(:running), do: "Current"
  defp tag(:upcoming), do: "Next"
  defp tag(:ended), do: "Ended"

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
