defmodule RailWeb.Components.DueLabel do
  @moduledoc "An initiative's expected date with its days left or late, or that it has none."
  use RailWeb, :html

  alias Rail.Initiatives.Schemas.Initiative

  attr :initiative, Initiative, required: true
  attr :today, Date, required: true
  attr :id, :string, default: nil

  def due_label(assigns) do
    due = Initiative.calculate_due(assigns.initiative, assigns.today)

    assigns =
      assigns
      |> assign(:show_none, is_nil(due))
      |> assign(:show_today, due == :today)
      |> assign(:show_late, match?({:late, _days}, due))
      |> assign(:show_left, match?({:left, _days}, due))
      |> assign(:text, Initiative.calculate_due_text(assigns.initiative, assigns.today))

    ~H"""
    <span
      :if={@show_none}
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs whitespace-nowrap text-slate-400 dark:text-slate-500"
    >
      <.icon name="pi-calendar-blank" class="h-3.5 w-3.5" />No expected date
    </span>
    <span
      :if={@show_today}
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs whitespace-nowrap font-semibold text-slate-900 dark:text-slate-100"
    >
      <.icon name="pi-calendar-check" class="h-3.5 w-3.5" />Due today
    </span>
    <span
      :if={@show_left}
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs whitespace-nowrap text-slate-500 dark:text-slate-400"
    >
      <.icon name="pi-calendar-blank" class="h-3.5 w-3.5" />{Calendar.strftime(
        @initiative.expected_on,
        "%b %-d"
      )} · {@text}
    </span>
    <span
      :if={@show_late}
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs whitespace-nowrap font-semibold text-red-600 dark:text-red-400"
    >
      <.icon name="pi-warning-circle" class="h-3.5 w-3.5" />{Calendar.strftime(
        @initiative.expected_on,
        "%b %-d"
      )} · {@text}
    </span>
    """
  end
end
