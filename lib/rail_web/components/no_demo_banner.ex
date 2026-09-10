defmodule RailWeb.Components.NoDemoBanner do
  @moduledoc """
  Component rendering the "No demo recorded" banner when a task reaches
  `:ready_to_merge` without a demo artifact. Implements Spec 05 §2.8.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  attr :task, :any, required: true

  @doc "Renders the no-demo banner card."
  def no_demo_banner(assigns) do
    task = assigns.task
    can_rerecord = can_rerecord?(task)
    assigns = assign(assigns, :can_rerecord, can_rerecord)

    ~H"""
    <div
      id="no-demo-banner"
      data-qa="no_demo_banner"
      class="p-4 rounded-xl bg-[var(--color-surface)] border border-[var(--color-border)] flex items-center justify-between gap-4"
    >
      <div class="flex items-start gap-3">
        <.icon
          name="videocam_off_outlined"
          class="h-5 w-5 shrink-0 mt-0.5 text-[var(--color-on-surface-variant)]"
        />
        <div class="space-y-0.5">
          <h4
            id="no-demo-title"
            data-qa="no_demo_title"
            class="text-sm font-bold text-[var(--color-on-surface)]"
          >
            No demo recorded
          </h4>
          <p
            id="no-demo-body"
            data-qa="no_demo_body"
            class="text-xs text-[var(--color-on-surface-variant)] leading-relaxed"
          >
            This task reached Ready to merge without recording a demo (gates were skipped).
          </p>
        </div>
      </div>

      <div :if={@can_rerecord} class="shrink-0">
        <button
          type="button"
          id="action-record-demo"
          data-qa="record_demo_button"
          phx-click="rerecord_demo"
          class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold text-[var(--color-primary)] hover:bg-[var(--color-primary)]/10 rounded-lg transition-colors cursor-pointer"
        >
          <.icon name="videocam_outlined" class="h-4 w-4 shrink-0" />
          <span>Record demo</span>
        </button>
      </div>
    </div>
    """
  end

  defp can_rerecord?(%Task{} = task), do: Pipeline.can_rerecord_demo?(task)

  defp can_rerecord?(task) when is_map(task) do
    # When plain map provided in tests, construct a Task struct for evaluation
    struct = struct(Task, task)
    Pipeline.can_rerecord_demo?(struct)
  end

  defp can_rerecord?(_other), do: false
end
