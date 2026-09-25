defmodule RailWeb.Live.ArchitectStage do
  @moduledoc """
  The implementation plan an architect run wrote, and the approval of it.

  The plan lives in scratch until a human reads it, so this is what reads it, and
  the button only exists when there is something to show. Refining it is the
  conversation in the sidebar: every message is another turn, and the architect
  writes the file again.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:plan, Pipeline.read_plan(assigns.task))
      |> assign_new(:error, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="architect-stage" data-qa="architect-stage" class="contents">
      <.task_layout task={@task} run={@run} stage_run={@stage_run} title={@task.issue.title}>
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:actions>
          {render_slot(@actions)}

          <button
            :if={@approvable and @plan != nil}
            type="button"
            id="approve-plan"
            data-qa="approve_plan"
            phx-click="approve"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Approve plan
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p
            id="architect-error"
            data-qa="architect_error"
            class="text-xs text-red-600 dark:text-red-500"
          >
            {@error}
          </p>
        </:alerts>

        <.plan_pending :if={@plan == nil} running={Run.running?(@run)} />

        <div
          :if={@plan != nil}
          id="architect-plan"
          data-qa="architect_plan"
          class="max-w-3xl mx-auto select-text"
        >
          <.markdown content={@plan} class="text-[15px] leading-relaxed" />
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("approve", _params, socket) do
    case Pipeline.approve_plan(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  attr :running, :boolean, required: true

  # Nothing to read yet. While the architect works, this says what is coming;
  # once it has stopped, the chat is where it resumes.
  defp plan_pending(assigns) do
    ~H"""
    <div
      id="architect-plan-pending"
      data-qa="architect_plan_pending"
      class="flex flex-col items-center gap-10 py-10"
    >
      <div class="flex flex-col items-center text-center max-w-md">
        <div class="relative flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
          <span
            :if={@running}
            class="absolute inset-0 rounded-2xl ring-2 ring-blue-400/40 motion-safe:animate-ping"
          />
          <.icon name={if @running, do: "pi-compass-tool", else: "pi-cube"} class="size-7" />
        </div>

        <h2
          id="architect-plan-pending-title"
          class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100"
        >
          {if @running, do: "Planning the implementation", else: "No plan yet"}
        </h2>

        <p :if={@running} class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          The architect is reading the ticket and the code it touches, then writing the
          plan an engineer builds from. It appears here once it is written.
        </p>

        <p :if={not @running} class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          The architect stopped before writing a plan. Send it a message in the
          conversation to pick up where it left off.
        </p>
      </div>

      <div class="w-full max-w-3xl space-y-3" aria-hidden="true">
        <div class={[
          "h-4 w-1/3 rounded bg-slate-200 dark:bg-slate-800",
          @running && "motion-safe:animate-pulse"
        ]} />
        <div
          :for={width <- ["w-full", "w-11/12", "w-4/5"]}
          class={["h-2.5 rounded bg-slate-100 dark:bg-slate-800/60", width]}
        />
      </div>
    </div>
    """
  end

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not architect."
  defp message_for(:no_plan), do: "The architect has not written a plan yet."
  # coveralls-ignore-start (a refusal nobody has written a sentence for yet)
  defp message_for(reason), do: "Could not approve the plan: #{inspect(reason)}"
  # coveralls-ignore-stop
end
