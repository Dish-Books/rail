defmodule RailWeb.Utils.RunStateStyle do
  @moduledoc """
  How a run's state looks: its icon, its colour, and the word on its pill.

  `Run.state/1` says what a run is doing; this is the one place that decides what
  that looks like, so a pill, a chip and a stepper node never disagree about what
  `:blocked` is.
  """

  alias Rail.Pipeline.Schemas.Run

  @doc """
  The look of `run`'s state: its Phosphor `icon`, Tailwind `text_class` and
  `chip_class`, and the `pill_label` a state pill shows.
  """
  def run_state_style(run) do
    state = Run.state(run)
    color = color_for(state)

    %{
      icon: icon_for(state),
      text_class: classes(color, :text),
      chip_class: classes(color, :chip),
      pill_label: pill_label(state)
    }
  end

  defp icon_for(:running), do: "pi-play-circle"
  defp icon_for(:queued), do: "pi-clock"
  defp icon_for(:blocked), do: "pi-question"
  defp icon_for(:failed), do: "pi-warning-circle"
  defp icon_for(:stopped), do: "pi-pause-circle"
  defp icon_for(:done), do: "pi-chat-text"

  defp pill_label(:running), do: "Running"
  defp pill_label(:blocked), do: "Needs you"
  defp pill_label(:failed), do: "Failed"
  defp pill_label(:done), do: "Done"
  defp pill_label(:stopped), do: "Stopped"
  defp pill_label(:queued), do: "Queued"

  defp color_for(:running), do: :primary
  defp color_for(state) when state in [:blocked, :done], do: :amber
  defp color_for(:failed), do: :error
  defp color_for(_idle), do: :outline

  defp classes(:primary, :text), do: "text-blue-600 dark:text-blue-500"
  defp classes(:amber, :text), do: "text-amber-700 dark:text-amber-300"
  defp classes(:outline, :text), do: "text-slate-500 dark:text-slate-400"
  defp classes(:error, :text), do: "text-red-600 dark:text-red-500"

  defp classes(:primary, :chip),
    do: "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border-blue-600 dark:border-blue-500"

  defp classes(:amber, :chip), do: "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 border-amber-500"

  defp classes(:outline, :chip),
    do: "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border-slate-500 dark:border-slate-400"

  defp classes(:error, :chip),
    do: "bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200 border-red-600 dark:border-red-500"
end
