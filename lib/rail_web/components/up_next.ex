defmodule RailWeb.Components.UpNext do
  @moduledoc """
  The runs waiting on a human, longest-waiting first.

  The first leads as a card and the rest follow as rows. Nothing here acts on a
  run: what the human does next — reading a ticket, answering a question — needs
  the task in front of them, so every entry is only a way there.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  attr :runs, :list, required: true

  def up_next(assigns) do
    assigns =
      assigns
      |> assign(:featured, List.first(assigns.runs))
      |> assign(:rest, Enum.drop(assigns.runs, 1))

    ~H"""
    <div id="up-next" data-qa="up-next" class="space-y-3">
      <p
        :if={@runs == []}
        id="up-next-empty"
        class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
      >
        Nothing is waiting on you.
      </p>

      <.link
        :if={@featured}
        navigate={~p"/tasks/#{@featured.task_id}"}
        id={"up-next-featured-#{@featured.id}"}
        data-qa="up-next-featured"
        class="group block rounded-xl border border-amber-300 dark:border-amber-800/70 bg-amber-50 dark:bg-amber-950/30 px-5 py-4 transition-colors hover:bg-amber-100/70 dark:hover:bg-amber-950/50"
      >
        <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
              <span
                data-qa="up-next-chip"
                class={[
                  "px-2 py-0.5 rounded text-[11px] font-bold uppercase tracking-wider",
                  tone(@featured).chip
                ]}
              >
                {chip(@featured)}
              </span>
              <span class="font-mono text-xs text-slate-600 dark:text-slate-400 truncate">
                {@featured.task.issue.identifier} · {@featured.role.name}
              </span>
            </div>

            <h3 class="mt-2 text-lg font-semibold leading-snug text-slate-900 dark:text-slate-100">
              {@featured.task.issue.title}
            </h3>

            <p data-qa="up-next-summary" class="mt-1 text-sm text-slate-600 dark:text-slate-400">
              {summary(@featured)}
            </p>
          </div>

          <span class={[
            "self-start sm:self-center shrink-0 px-4 py-2 rounded-lg text-sm font-semibold transition-colors",
            tone(@featured).action
          ]}>
            {action(@featured)}
          </span>
        </div>
      </.link>

      <.link
        :for={run <- @rest}
        navigate={~p"/tasks/#{run.task_id}"}
        id={"up-next-row-#{run.id}"}
        data-qa="up-next-row"
        class="group flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 px-5 py-3.5 transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/70"
      >
        <span class="font-mono text-xs text-slate-500 dark:text-slate-400 shrink-0 w-16">
          {run.task.issue.identifier}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm text-slate-900 dark:text-slate-100">
          {run.task.issue.title} ·
          <span class="text-slate-500 dark:text-slate-400">{detail(run)}</span>
        </span>
        <span class="shrink-0 text-sm font-semibold text-blue-600 dark:text-blue-400 group-hover:underline">
          {verb(run)}
        </span>
      </.link>
    </div>
    """
  end

  # Three things bring a run here, and they are not the same errand. A done run has
  # produced the work of its stage and waits on that being read. A blocked run
  # waits on its questions. A run that failed or stopped waits on someone picking
  # it up, and says nothing about itself until they do.
  defp chip(run) do
    case Run.state(run) do
      :done -> "Ready for review"
      :blocked -> "Needs an answer"
      _stalled -> "Needs a fix"
    end
  end

  defp action(run) do
    case Run.state(run) do
      :done -> "Review #{work(run)}"
      :blocked -> "Answer questions"
      _stalled -> "Pick it up"
    end
  end

  defp verb(run) do
    case Run.state(run) do
      :done -> "Review"
      :blocked -> "Answer"
      _stalled -> "Fix"
    end
  end

  defp summary(run) do
    case Run.state(run) do
      :done -> "The #{work(run)} is ready for you to review."
      :blocked -> asked(run)
      _stalled -> stalled(run)
    end
  end

  defp detail(run) do
    case Run.state(run) do
      :done -> "#{work(run)} ready for review"
      :blocked -> "#{run.role.name} asked #{questions(run)}"
      _stalled -> stalled(run)
    end
  end

  defp asked(run) do
    case Enum.find(run.questions, &(&1.status == :pending)) do
      %Question{prompt: prompt} -> prompt
      nil -> "Every question is answered and ready to send."
    end
  end

  # What a failed run left behind is the error; a stopped one left nothing, and
  # what it needs is the same either way.
  defp stalled(%Run{error: error}) when is_binary(error), do: error

  defp stalled(%Run{} = run) do
    "#{run.role.name} stopped before finishing. Send it a message to pick up where it left off."
  end

  # A stage that stalled is a problem rather than a queue, and reads as one.
  defp tone(run) do
    if Run.state(run) in [:failed, :stopped] do
      %{chip: "bg-red-500 text-white", action: "bg-red-500 text-slate-950 group-hover:bg-red-400"}
    else
      %{chip: "bg-amber-500 text-slate-950", action: "bg-amber-500 text-slate-950 group-hover:bg-amber-400"}
    end
  end

  defp work(%Run{task: %Task{stage: :design}}), do: "design"
  defp work(%Run{task: %Task{stage: :architect}}), do: "plan"
  defp work(%Run{task: %Task{stage: :engineer}}), do: "implementation"
  defp work(%Run{}), do: "ticket"

  defp questions(%Run{questions: [_one]}), do: "a question"
  defp questions(%Run{questions: questions}), do: "#{length(questions)} questions"
end
