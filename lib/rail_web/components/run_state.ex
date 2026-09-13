defmodule RailWeb.Components.RunState do
  @moduledoc """
  How a run's state looks: its icon, its colour, and the word on its pill.

  `Run.state/1` says what a run is doing; this is the one place that decides what
  that looks like, so a pill, a chip and a stepper node never disagree about what
  `:blocked` is.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  @doc """
  The Phosphor icon for `run`, in the context of `task`.
  """
  def icon(task, run) do
    if Task.conflicted?(task), do: "pi-git-branch", else: icon_for(task, Run.state(run))
  end

  @doc """
  The semantic colour for `run` — `:primary`, `:amber`, `:outline` or `:error`.
  """
  def color(task, run) do
    if Task.conflicted?(task), do: :amber, else: color_for(Run.state(run))
  end

  @doc """
  Tailwind classes for `run`'s colour, as text or as a chip.
  """
  def color_class(task, run, variant \\ :text), do: classes(color(task, run), variant)

  @doc """
  The word a state pill shows.
  """
  def pill_label(:running), do: "Running"
  def pill_label(:blocked), do: "Needs you"
  def pill_label(:failed), do: "Failed"
  def pill_label(:done), do: "Done"
  def pill_label(:stopped), do: "Stopped"
  def pill_label(_queued), do: "Queued"

  @doc """
  Tailwind classes for a state pill.
  """
  def pill_class(state), do: state |> color_for() |> classes(:chip)

  defp icon_for(_task, :running), do: "pi-play-circle"
  defp icon_for(_task, :queued), do: "pi-clock"
  defp icon_for(_task, :blocked), do: "pi-question"
  defp icon_for(_task, :failed), do: "pi-warning-circle"
  defp icon_for(_task, :stopped), do: "pi-pause-circle"
  defp icon_for(%Task{stage: :ready_to_merge}, :done), do: "pi-git-merge"
  defp icon_for(_task, :done), do: "pi-chat-text"

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
