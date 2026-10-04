defmodule RailWeb.Components.LearningStatus do
  @moduledoc """
  Where a rule stands, as one label: Flagged while an override waits on a
  person, otherwise its status. An Auto badge follows a rule nobody approved.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning

  attr :learning, Learning, required: true
  attr :flagged, :boolean, default: false

  def learning_status(assigns) do
    {label, icon, tone} = calculate_label(assigns.learning, assigns.flagged)
    assigns = assigns |> assign(:label, label) |> assign(:icon, icon) |> assign(:tone, tone)

    ~H"""
    <span
      data-qa="learning-status"
      class={["inline-flex items-center gap-1 whitespace-nowrap text-[11px] font-semibold", @tone]}
    >
      <.icon name={@icon} class="size-[13px]" />{@label}
    </span>
    <span
      :if={@learning.auto}
      data-qa="learning-auto"
      class="inline-flex items-center gap-1 whitespace-nowrap px-1.5 py-px rounded border border-slate-300 dark:border-slate-600 text-[10px] font-semibold text-slate-600 dark:text-slate-300"
    >
      <.icon name="pi-sparkle" class="size-[11px]" />Auto
    </span>
    """
  end

  # Amber is a person being waited on, which is exactly what a flagged rule is.
  defp calculate_label(%Learning{status: status}, true) when status in [:active, :provisional],
    do: {"Flagged", "pi-flag-fill", "text-amber-600 dark:text-amber-400"}

  defp calculate_label(%Learning{status: :active}, _flagged),
    do: {"Active", "pi-check-circle-fill", "text-emerald-600 dark:text-emerald-400"}

  defp calculate_label(%Learning{status: :provisional}, _flagged),
    do: {"Provisional", "pi-clock", "text-blue-600 dark:text-blue-400"}

  defp calculate_label(%Learning{status: :retired}, _flagged),
    do: {"Retired", "pi-archive", "text-slate-500 dark:text-slate-400"}

  defp calculate_label(%Learning{status: :proposed}, _flagged),
    do: {"Proposed", "pi-note-pencil", "text-slate-500 dark:text-slate-400"}
end
