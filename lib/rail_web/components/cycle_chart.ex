defmodule RailWeb.Components.CycleChart do
  @moduledoc """
  A cycle's burnup from Linear's daily history: scope, started and completed, the target line, hatched weekends and a
  rule on today. Each of `days` adds that day's figures and hidden marker, which the panel's `CycleFigures` hook shows.
  """
  use RailWeb, :html

  @left 4
  @right 316
  @top 8
  @bottom 128

  attr :cycle, :map, required: true
  attr :label, :string, required: true
  attr :today, :any, required: true
  attr :id_prefix, :string, default: "cycle"
  # One map of `data-*` figures per day with history, oldest first; `CyclePanel` builds them.
  attr :days, :list, default: []

  def cycle_chart(assigns) do
    %{cycle: cycle, today: today} = assigns
    days = max(Date.diff(cycle.ends_on, cycle.starts_on) + 1, 1)
    step = if days > 1, do: (@right - @left) / (days - 1), else: 0
    histories = [cycle.scope_history, cycle.started_history, cycle.completed_history]
    peak = histories |> List.flatten() |> Enum.max(fn -> 0 end)
    ceiling = max(peak * 1.1, 1)
    x = fn index -> @left + index * step end
    y = fn value -> @bottom - value / ceiling * (@bottom - @top) end
    last = length(cycle.scope_history) - 1
    dates = Enum.map(0..(days - 1), &Date.add(cycle.starts_on, &1))

    assigns =
      assigns
      |> assign(:grid, [@bottom, (@bottom + @top) / 2, @top])
      |> assign_lines(x, y)
      |> assign(:projection, cycle.status == :running && projection(cycle.scope_history, last, days, x, y))
      |> assign(:today_x, today_x(cycle, today, days, x))
      |> assign(:ends, ends(cycle, x, y))
      |> assign(:weekends, weekends(dates, x))
      |> assign(:target_path, dates |> target_values(List.last(cycle.scope_history) || 0) |> line_path(x, y))
      |> assign(:markers, markers(assigns.days, cycle, x, y))
      |> assign(:day_rects, day_rects(assigns.days, x, step))
      |> assign(:summary, summary(assigns.label, cycle))
      |> assign(:date_labels, date_labels(cycle, days, x))

    ~H"""
    <figure id={"#{@id_prefix}-chart"} class="m-0 max-w-sm">
      <svg
        viewBox="0 0 320 150"
        class="w-full h-auto rounded touch-pan-y focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        role="img"
        aria-label={@summary}
        tabindex={@day_rects != [] && "0"}
      >
        <defs>
          <pattern
            id={"#{@id_prefix}-hatch"}
            width="6"
            height="6"
            patternUnits="userSpaceOnUse"
            patternTransform="rotate(45)"
          >
            <rect width="6" height="6" fill="#64748b" fill-opacity="0.10" />
            <line
              x1="0"
              y1="0"
              x2="0"
              y2="6"
              stroke="#64748b"
              stroke-opacity="0.28"
              stroke-width="1.5"
            />
          </pattern>
        </defs>
        <rect
          :for={{band_x, band_width} <- @weekends}
          x={band_x}
          y="8"
          width={band_width}
          height="120"
          fill={"url(##{@id_prefix}-hatch)"}
        />
        <line
          :for={line_y <- @grid}
          x1="4"
          x2="316"
          y1={coord(line_y)}
          y2={coord(line_y)}
          stroke="currentColor"
          class="text-slate-200 dark:text-slate-800"
          stroke-width="1"
        />
        <line
          :if={@today_x}
          id={"#{@id_prefix}-chart-today"}
          x1={@today_x}
          x2={@today_x}
          y1="8"
          y2="128"
          stroke="currentColor"
          class="text-slate-400 dark:text-slate-600"
          stroke-width="1"
        />
        <path
          :if={@scope_path}
          d={@scope_path}
          stroke="#94a3b8"
          stroke-width="2"
          stroke-dasharray="3 3"
          fill="none"
        />
        <path
          :if={@projection}
          d={@projection}
          stroke="#94a3b8"
          stroke-width="2"
          stroke-dasharray="3 3"
          fill="none"
          opacity="0.5"
        />
        <path
          :if={@target_path}
          d={@target_path}
          stroke="#e879f9"
          stroke-width="1.5"
          stroke-dasharray="7 4"
          fill="none"
          data-line="target"
        />
        <path
          :if={@started_path}
          d={@started_path}
          stroke="#0d9488"
          stroke-width="2"
          fill="none"
          stroke-linejoin="round"
        />
        <path
          :if={@completed_path}
          d={@completed_path}
          stroke="#6366f1"
          stroke-width="2"
          fill="none"
          stroke-linejoin="round"
        />
        <circle
          :for={{cx, cy, color} <- @ends}
          cx={cx}
          cy={cy}
          r="4"
          fill={color}
          stroke-width="2"
          class="stroke-white dark:stroke-slate-900"
        />
        <g :for={marker <- @markers} data-marker={marker.index} class="hidden">
          <line
            x1={marker.x}
            x2={marker.x}
            y1="8"
            y2="128"
            stroke="currentColor"
            class="text-slate-300"
            stroke-width="1.5"
          />
          <circle
            :for={{cy, color} <- marker.dots}
            cx={marker.x}
            cy={cy}
            r="3.5"
            fill={color}
            stroke-width="2"
            class="stroke-white dark:stroke-slate-900"
          />
        </g>
        <rect
          :for={day <- @day_rects}
          data-day={day.index}
          x={day.x}
          y="8"
          width={day.width}
          height="120"
          fill="transparent"
          {day.figures}
        />
        <text
          :for={{text_x, anchor, date} <- @date_labels}
          x={text_x}
          y="144"
          text-anchor={anchor}
          class="fill-slate-500 dark:fill-slate-400"
          font-size="11"
        >
          {Calendar.strftime(date, "%b %-d")}
        </text>
      </svg>
    </figure>
    <p
      :if={@target_path || @weekends != []}
      id={"#{@id_prefix}-chart-legend"}
      class="flex items-center gap-3 flex-wrap text-xs text-slate-500 dark:text-slate-400"
    >
      <span :if={@target_path} class="inline-flex items-center gap-1.5">
        <svg width="22" height="6" aria-hidden="true">
          <line
            x1="0"
            y1="3"
            x2="22"
            y2="3"
            stroke="#e879f9"
            stroke-width="1.5"
            stroke-dasharray="7 4"
          />
        </svg>
        Target
      </span>
      <span :if={@weekends != []} class="inline-flex items-center gap-1.5">
        <svg width="14" height="10" aria-hidden="true">
          <rect width="14" height="10" rx="1" fill="#64748b" fill-opacity="0.25" />
          <path d="M0 10L10 0M5 10L14 1" stroke="#64748b" stroke-width="1.2" />
        </svg>
        Weekend
      </span>
    </p>
    """
  end

  defp assign_lines(%{cycle: cycle} = assigns, x, y) do
    assigns
    |> assign(:scope_path, line_path(cycle.scope_history, x, y))
    |> assign(:started_path, line_path(cycle.started_history, x, y))
    |> assign(:completed_path, line_path(cycle.completed_history, x, y))
  end

  defp line_path([], _x, _y), do: nil

  defp line_path(values, x, y) do
    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} -> "#{coord(x.(index))},#{coord(y.(value))}" end)
    |> then(&("M" <> String.replace(&1, " ", " L")))
  end

  defp today_x(%{status: :running} = cycle, today, days, x) do
    index = Date.diff(today, cycle.starts_on)
    if index in 0..(days - 1), do: coord(x.(index))
  end

  defp today_x(_cycle, _today, _days, _x), do: nil

  # While it runs, scope carries on flat from today to the last day, faded, so the chart spans the whole cycle.
  defp projection(values, last, days, x, y) when last >= 0 and last < days - 1 do
    value_y = coord(y.(List.last(values)))
    "M#{coord(x.(last))},#{value_y} L#{coord(x.(days - 1))},#{value_y}"
  end

  defp projection(_values, _last, _days, _x, _y), do: nil

  defp ends(cycle, x, y) do
    for {values, color} <- [{cycle.started_history, "#0d9488"}, {cycle.completed_history, "#6366f1"}], values != [] do
      {coord(x.(length(values) - 1)), coord(y.(List.last(values))), color}
    end
  end

  # Each gap leaving a weekday earns the same share of the scope, so the line rests from Saturday to Monday.
  defp target_values(dates, full) do
    weights = for date <- Enum.drop(dates, -1), do: if(Date.day_of_week(date) <= 5, do: 1, else: 0)
    total = Enum.sum(weights)

    if total > 0,
      do: weights |> Enum.scan(&(&1 + &2)) |> then(&[0 | &1]) |> Enum.map(&(full * &1 / total)),
      else: []
  end

  # From each Saturday, or a Sunday the cycle opens on, to the Monday after, cut off at the last day.
  defp weekends(dates, x) do
    last = length(dates) - 1

    for {date, index} <- Enum.with_index(dates),
        weekday = Date.day_of_week(date),
        weekday == 6 or (weekday == 7 and index == 0),
        index < last do
      {coord(x.(index)), coord(x.(min(index + 8 - weekday, last)) - x.(index))}
    end
  end

  defp markers(days, cycle, x, y) do
    histories = [
      {cycle.scope_history, "#94a3b8"},
      {cycle.started_history, "#0d9488"},
      {cycle.completed_history, "#6366f1"}
    ]

    for index <- 0..(length(days) - 1)//1 do
      dots = for {values, color} <- histories, value = Enum.at(values, index), do: {coord(y.(value)), color}
      %{index: index, x: coord(x.(index)), dots: dots}
    end
  end

  # One day wide around its point, so no two overlap and the pointer always reads the nearest day.
  defp day_rects(days, x, step) do
    days
    |> Enum.with_index()
    |> Enum.map(fn {figures, index} ->
      left = if step > 0, do: max(x.(index) - step / 2, @left), else: @left
      right = if step > 0, do: min(x.(index) + step / 2, @right), else: @right
      %{index: index, x: coord(left), width: coord(right - left), figures: figures}
    end)
  end

  defp date_labels(cycle, days, x) do
    middle = div(days - 1, 2)

    [
      {coord(@left), "start", cycle.starts_on},
      {coord(x.(middle)), "middle", Date.add(cycle.starts_on, middle)},
      {coord(@right), "end", cycle.ends_on}
    ]
  end

  defp summary(label, cycle) do
    [scope, started, completed] =
      Enum.map([cycle.scope_history, cycle.started_history, cycle.completed_history], &round(List.last(&1) || 0))

    "#{label}: scope #{scope} points, started #{started}, completed #{completed}"
  end

  defp coord(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end
