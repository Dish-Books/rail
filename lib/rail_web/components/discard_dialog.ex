defmodule RailWeb.Components.DiscardDialog do
  @moduledoc """
  The task page's Discard confirmation: on a task past Plan, the choice of starting over or going Back to Plan, then
  the runs it stops, what it deletes and where it leaves the ticket. An error stays in the dialog, to try again.
  """
  use RailWeb, :html

  import RailWeb.Utils.RunStateStyle, only: [run_state_style: 1]

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @choices [
    %{value: :discard, title: "Start over", detail: "Deletes the task and puts the ticket back to not started"},
    %{value: :plan, title: "Back to Plan", detail: "Keeps the ticket, design and plan"}
  ]

  attr :task, Task, required: true, doc: "with its issue and its runs, each with its role and questions"
  attr :discarding, :boolean, default: false
  attr :error, :string, default: nil
  attr :stopped, :boolean, default: false, doc: "whether the runs listed when it was confirmed were stopped"
  attr :choice, :atom, default: :discard, values: [:discard, :plan]
  attr :back_to_plan, :boolean, default: false, doc: "whether Back to Plan is offered"

  def discard_dialog(assigns) do
    %Task{issue: %Issue{} = issue, runs: runs} = assigns.task

    running =
      for run <- Enum.sort_by(runs, &(&1.started_at || &1.inserted_at), DateTime),
          Run.running?(run) or Run.state(run) == :blocked do
        %{id: run.id, name: run.role.name, style: run_state_style(run)}
      end

    runs_heading =
      cond do
        running != [] -> "Stops #{length(running)} #{if length(running) == 1, do: "run", else: "runs"} in progress"
        assigns.stopped -> "Runs stopped"
        true -> "No runs in progress"
      end

    %{title: title, files_title: files_title, files_detail: files_detail, target: target, target_label: target_label} =
      copy(assigns.choice, issue.identifier)

    assigns =
      assigns
      |> assign(:identifier, issue.identifier)
      |> assign(:title, title)
      |> assign(:files_title, files_title)
      |> assign(:files_detail, files_detail)
      |> assign(:target, target)
      |> assign(:target_label, target_label)
      |> assign(:choices, for(choice <- @choices, do: Map.put(choice, :checked, choice.value == assigns.choice)))
      |> assign(:running, running)
      |> assign(:runs_heading, runs_heading)
      |> assign(:status, issue.state_name || Issue.state_label(issue.state))
      |> assign(:finished, Issue.finished_state?(issue.state))
      |> assign(:confirm_label, confirm_label(assigns))

    ~H"""
    <div
      id="discard-dialog-backdrop"
      class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 p-4 pt-24 overflow-y-auto"
      phx-window-keydown="close_discard"
      phx-key="Escape"
    >
      <div
        id="discard-dialog"
        data-qa="discard_dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="discard-title"
        class="w-[560px] max-w-full rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4 text-sm text-slate-900 dark:text-slate-100"
      >
        <div class="flex items-center justify-between gap-3 border-b border-slate-200 dark:border-slate-700 pb-3">
          <h2 id="discard-title" class="text-base font-semibold min-w-0 break-words">
            {@title}
          </h2>
          <button
            type="button"
            id="close-discard-dialog"
            aria-label="Close"
            phx-click="close_discard"
            class="shrink-0 p-1 rounded-sm text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="size-[18px]" />
          </button>
        </div>

        <div :if={@back_to_plan} role="radiogroup" aria-label="What Discard does" class="flex gap-2">
          <label
            :for={choice <- @choices}
            id={"discard-choice-#{choice.value}"}
            data-qa={"discard_choice_#{choice.value}"}
            class={[
              "flex-1 min-w-0 flex gap-2.5 rounded-xl px-3 py-2.5 cursor-pointer has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-blue-500",
              choice.checked && "ring-2 ring-blue-500 bg-blue-500/10",
              !choice.checked &&
                "ring-1 ring-slate-300 dark:ring-slate-700 hover:bg-slate-50 dark:hover:bg-slate-800"
            ]}
          >
            <input
              type="radio"
              name="discard_choice"
              value={choice.value}
              checked={choice.checked}
              disabled={@discarding}
              phx-click="pick_discard"
              phx-value-choice={choice.value}
              class="sr-only"
            />
            <span class={[
              "mt-0.5 size-4 shrink-0 rounded-full",
              choice.checked && "border-4 border-blue-500 bg-white",
              !choice.checked && "border border-slate-400 dark:border-slate-500"
            ]} />
            <span class="min-w-0">
              <span class="block font-semibold">{choice.title}</span>
              <span class="block text-xs text-slate-500 dark:text-slate-400">{choice.detail}</span>
            </span>
          </label>
        </div>

        <ul class="space-y-4">
          <li id="discard-runs" class="flex gap-3 min-w-0">
            <.icon name="pi-stop-circle" class="size-[18px] text-slate-400 mt-0.5" />
            <div class="min-w-0 flex-1">
              <p class="font-semibold">{@runs_heading}</p>
              <ul :if={@running != []} class="mt-1.5 space-y-1 text-slate-600 dark:text-slate-300">
                <li
                  :for={run <- @running}
                  id={"discard-run-#{run.id}"}
                  data-qa="discard_run"
                  class="flex items-center justify-between gap-2 min-w-0"
                >
                  <span class="truncate">{run.name}</span>
                  <span class={[
                    "shrink-0 inline-flex items-center gap-1 text-xs font-semibold",
                    run.style.text_class
                  ]}>
                    <.icon name={run.style.icon} class="size-3.5" />
                    {run.style.pill_label}
                  </span>
                </li>
              </ul>
            </div>
          </li>
          <li id="discard-files" class="flex gap-3 min-w-0">
            <.icon name="pi-folder-minus" class="size-[18px] text-slate-400 mt-0.5" />
            <div class="min-w-0 flex-1">
              <p class="font-semibold">{@files_title}</p>
              <p class="text-slate-500 dark:text-slate-400">{@files_detail}</p>
            </div>
          </li>
          <li id="discard-branch" class="flex gap-3 min-w-0">
            <.icon name="pi-git-branch" class="size-[18px] text-slate-400 mt-0.5" />
            <div class="min-w-0 flex-1">
              <p class="font-semibold">Deletes the branch here and on GitHub</p>
              <p
                class="font-mono text-[12px] text-slate-500 dark:text-slate-400 truncate"
                title={@task.worktree_name}
              >
                {@task.worktree_name}
              </p>
              <p
                :if={@task.pr_number}
                id="discard-pull-request"
                class="text-slate-500 dark:text-slate-400"
              >
                GitHub closes
                <.link
                  :if={@task.pr_url}
                  href={@task.pr_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-mono text-blue-600 dark:text-blue-400 hover:underline"
                >
                  PR #{@task.pr_number}
                </.link>
                <span :if={!@task.pr_url} class="font-mono">PR #{@task.pr_number}</span>
                without merging it.
              </p>
            </div>
          </li>
          <li id="discard-ticket" class="flex gap-3 min-w-0">
            <.icon name="pi-ticket" class="size-[18px] text-slate-400 mt-0.5" />
            <div :if={!@finished} class="min-w-0 flex-1">
              <p class="font-semibold">Moves {@identifier} back to {@target}</p>
              <p class="flex flex-wrap items-center gap-1 text-slate-500 dark:text-slate-400">
                <span>{@status}</span>
                <.icon name="pi-arrow-right" class="size-3.5" />
                <span class="text-slate-900 dark:text-slate-200">{@target_label}</span>
              </p>
            </div>
            <div :if={@finished} class="min-w-0 flex-1">
              <p class="font-semibold">Leaves {@identifier} at {@status}</p>
              <p class="text-slate-500 dark:text-slate-400">
                The ticket is already finished, so its status stays.
              </p>
            </div>
          </li>
        </ul>

        <div
          :if={@error}
          id="discard-error"
          role="alert"
          class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950 px-3 py-2 text-sm text-red-800 dark:text-red-200 flex gap-2 min-w-0"
        >
          <.icon name="pi-warning-circle-bold" class="size-4 text-red-600 dark:text-red-400 mt-0.5" />
          <p class="min-w-0 break-words whitespace-pre-line">{@error}</p>
        </div>

        <div class="flex justify-end gap-2 pt-1">
          <.button
            id="cancel-discard"
            phx-click="close_discard"
            phx-mounted={JS.focus()}
            disabled={@discarding}
          >
            Cancel
          </.button>
          <.button
            id="confirm-discard"
            data-qa="confirm_discard"
            variant="danger_solid"
            phx-click="discard"
            disabled={@discarding}
          >
            {@confirm_label}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp copy(:plan, identifier) do
    %{
      title: "Take #{identifier} back to Plan?",
      files_title: "Deletes the worktree and all the work on it",
      files_detail:
        "Runs, findings, comments and later rounds go. The ticket, design and plan stay, and Plan starts a new conversation on them.",
      target: "In Progress",
      target_label: "In Progress"
    }
  end

  defp copy(:discard, identifier) do
    %{
      title: "Discard #{identifier} and start over?",
      files_title: "Deletes the task, its worktree and scratch folder",
      files_detail: "Its runs, questions, findings and comments go too. Clean up keeps them.",
      target: "not started",
      target_label: "Not started"
    }
  end

  defp confirm_label(%{discarding: true, choice: :plan}), do: "Going back…"
  defp confirm_label(%{discarding: true}), do: "Discarding…"
  defp confirm_label(%{error: "" <> _error, choice: :plan}), do: "Back to Plan again"
  defp confirm_label(%{error: "" <> _error}), do: "Discard again"
  defp confirm_label(%{choice: :plan}), do: "Back to Plan"
  defp confirm_label(_assigns), do: "Discard"
end
