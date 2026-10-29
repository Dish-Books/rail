defmodule RailWeb.Utils.RunStateStyle do
  @moduledoc """
  How a run's state looks: its icon, its colour, and the word on its pill.

  `Run.state/1` says what a run is doing; this is the one place that decides what
  that looks like, so a pill, a chip and a stepper node never disagree about what
  `:blocked` is.
  """

  import RailWeb.Utils.StageLabel, only: [custom_stage_waiting?: 2, finalize_label: 1, review_waiting?: 2]

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc """
  The look of `run`'s state: its Phosphor `icon`, Tailwind `text_class` and
  `chip_class`, and the `pill_label` a state pill shows.
  """
  def run_state_style(%Run{status: :waiting_for_usage}) do
    %{
      icon: "pi-gauge",
      text_class: classes(:violet, :text),
      chip_class: classes(:violet, :chip),
      pill_label: "Waiting for usage"
    }
  end

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

  @doc """
  The look of `run`'s state on `task`, which gives a Review round waiting on a person the Findings icon. A task
  at Finalize, or merged, looks like where it stands there, whatever its run is doing.
  """
  def run_state_style(_run, %Task{stage: stage} = task) when stage in [:finalize, :merged] do
    state = if stage == :merged, do: :merged, else: Task.finalize_state(task)
    color = finalize_color(state)

    %{
      icon: finalize_icon(state),
      text_class: classes(color, :text),
      chip_class: classes(color, :chip),
      pill_label: finalize_label(state)
    }
  end

  # A custom stage's stopped agent waits on a person, for its Approve or for a message to save its file.
  def run_state_style(run, %Task{stage: :custom} = task) do
    style = run_state_style(run)

    cond do
      custom_stage_waiting?(task, run) -> %{style | icon: "pi-hand-pointing", text_class: classes(:amber, :text)}
      Run.state(run) == :stopped -> %{style | icon: "pi-warning-circle", text_class: classes(:amber, :text)}
      true -> style
    end
  end

  def run_state_style(run, task) do
    style = run_state_style(run)
    if review_waiting?(task, run), do: %{style | icon: "pi-list-checks"}, else: style
  end

  defp finalize_icon(:not_ready), do: "pi-flag"
  defp finalize_icon(:ready), do: "pi-seal-check"
  defp finalize_icon(:merging), do: "pi-circle-notch"
  defp finalize_icon(:refused), do: "pi-warning-circle"
  defp finalize_icon(:merged), do: "pi-git-merge"

  defp finalize_color(state) when state in [:not_ready, :ready], do: :amber
  defp finalize_color(:merging), do: :primary
  defp finalize_color(:refused), do: :error
  defp finalize_color(:merged), do: :emerald

  defp icon_for(:running), do: "pi-play-circle"
  defp icon_for(:waiting), do: "pi-hourglass-medium"
  defp icon_for(:queued), do: "pi-clock"
  defp icon_for(:blocked), do: "pi-question"
  defp icon_for(:failed), do: "pi-warning-circle"
  defp icon_for(:stopped), do: "pi-pause-circle"
  defp icon_for(:done), do: "pi-chat-text"

  defp pill_label(:running), do: "Running"
  defp pill_label(:waiting), do: "Waiting for resources"
  defp pill_label(:blocked), do: "Needs you"
  defp pill_label(:failed), do: "Failed"
  defp pill_label(:done), do: "Done"
  defp pill_label(:stopped), do: "Stopped"
  defp pill_label(:queued), do: "Queued"

  defp color_for(:running), do: :primary
  # Violet, not amber: nothing waiting for resources is waiting on a person.
  defp color_for(:waiting), do: :violet
  defp color_for(state) when state in [:blocked, :done], do: :amber
  defp color_for(:failed), do: :error
  defp color_for(_idle), do: :outline

  defp classes(:primary, :text), do: "text-blue-600 dark:text-blue-500"
  defp classes(:amber, :text), do: "text-amber-700 dark:text-amber-300"
  defp classes(:violet, :text), do: "text-violet-600 dark:text-violet-400"
  defp classes(:outline, :text), do: "text-slate-500 dark:text-slate-400"
  defp classes(:error, :text), do: "text-red-600 dark:text-red-500"
  defp classes(:emerald, :text), do: "text-emerald-600 dark:text-emerald-400"

  defp classes(:primary, :chip),
    do: "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border-blue-600 dark:border-blue-500"

  defp classes(:amber, :chip), do: "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 border-amber-500"

  defp classes(:violet, :chip),
    do:
      "bg-violet-100 dark:bg-violet-950/40 text-violet-700 dark:text-violet-300 border-violet-600 dark:border-violet-500/30"

  defp classes(:outline, :chip),
    do: "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border-slate-500 dark:border-slate-400"

  defp classes(:emerald, :chip),
    do:
      "bg-emerald-100 dark:bg-emerald-950/60 text-emerald-800 dark:text-emerald-300 border-emerald-600 dark:border-emerald-500"

  defp classes(:error, :chip),
    do: "bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200 border-red-600 dark:border-red-500"
end
