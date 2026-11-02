defmodule RailWeb.Components.CycleChart do
  @moduledoc """
  A cycle's burnup across its days, drawn from Linear's daily history: scope dashed, started and completed solid,
  with a rule on today while it runs. Each day carries a title reading its three values, rounded to whole points.
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
    today_index = Date.diff(today, cycle.starts_on)

    assigns =
      assigns
      |> assign(:grid, [@bottom, (@bottom + @top) / 2, @top])
      |> assign(:scope_path, line_path(cycle.scope_history, x, y))
      |> assign(:started_path, line_path(cycle.started_history, x, y))
      |> assign(:completed_path, line_path(cycle.completed_history, x, y))
      |> assign(:projection, cycle.status == :running && projection(cycle.scope_history, last, days, x, y))
      |> assign(:today_x, if(cycle.status == :running and today_index in 0..(days - 1), do: coord(x.(today_index))))
      |> assign(:ends, ends(cycle, x, y))
      |> assign(:day_rects, day_rects(cycle, x))
      |> assign(:summary, summary(assigns.label, cycle))
      |> assign(:date_labels, date_labels(cycle, days, x))

    ~H"""
    <figure id={"#{@id_prefix}-chart"} class="m-0 max-w-sm">
      <svg viewBox="0 0 320 150" class="w-full h-auto" role="img" aria-label={@summary}>
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
        <rect
          :for={{rect_x, title} <- @day_rects}
          x={rect_x}
          y="8"
          width="16"
          height="120"
          fill="transparent"
        >
          <title>{title}</title>
        </rect>
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
    """
  end

  defp line_path([], _x, _y), do: nil

  defp line_path(values, x, y) do
    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} -> "#{coord(x.(index))},#{coord(y.(value))}" end)
    |> then(&("M" <> String.replace(&1, " ", " L")))
  end

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

  defp day_rects(cycle, x) do
    cycle.scope_history
    |> Enum.with_index()
    |> Enum.map(fn {scope, index} ->
      started = Enum.at(cycle.started_history, index, 0)
      completed = Enum.at(cycle.completed_history, index, 0)

      {coord(x.(index) - 8),
       "Day #{index + 1}: scope #{round(scope)}, started #{round(started)}, completed #{round(completed)}"}
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
