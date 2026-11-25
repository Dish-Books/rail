defmodule RailWeb.Components.CoderabbitDialog do
  @moduledoc """
  The task page's confirmation before asking CodeRabbit for a review: the comment it posts and from whose account,
  the hourly review it spends, and, at Finalize, that the task goes back to Review. While a review is still waiting
  it says so and asks nothing. An error stays in the dialog, to try again.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Task

  attr :task, Task, required: true
  attr :reviews, :list, required: true, doc: "the task's CodeRabbit reviews, oldest first"
  attr :login, :string, default: nil, doc: "the reader's GitHub login, when they have one"
  attr :error, :string, default: nil

  def coderabbit_dialog(assigns) do
    reviews = assigns.reviews
    full? = not Enum.any?(reviews, &(&1.status == :done))

    assigns =
      assigns
      |> assign(:waiting, Enum.any?(reviews, &CoderabbitReview.pending?/1))
      |> assign(:command, if(full?, do: "@coderabbitai full review", else: "@coderabbitai review"))
      |> assign(
        :reads,
        if(full?, do: "It reads the whole pull request.", else: "It reads only the commits since its last review.")
      )
      |> assign(:account, if(assigns.login, do: "your GitHub account, #{assigns.login}", else: "your GitHub account"))
      |> assign(:spent, spent(length(reviews)))
      |> assign(:show_finalize, assigns.task.stage == :finalize)

    ~H"""
    <div
      id="coderabbit-dialog-backdrop"
      class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 p-4 pt-24 overflow-y-auto"
      phx-window-keydown="close_coderabbit"
      phx-key="Escape"
    >
      <div
        id="coderabbit-dialog"
        data-qa="coderabbit_dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="coderabbit-title"
        class="w-[520px] max-w-full rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4 text-sm text-slate-900 dark:text-slate-100"
      >
        <div class="flex items-center justify-between gap-3 border-b border-slate-200 dark:border-slate-700 pb-3">
          <h2 id="coderabbit-title" class="text-base font-semibold min-w-0 break-words">
            Ask CodeRabbit to review PR #{@task.pr_number}?
          </h2>
          <button
            type="button"
            id="close-coderabbit-dialog"
            aria-label="Close"
            phx-click="close_coderabbit"
            class="shrink-0 p-1 rounded-sm text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="size-[18px]" />
          </button>
        </div>

        <p :if={@waiting} id="coderabbit-waiting" class="flex gap-3 min-w-0">
          <.icon
            name="pi-circle-notch"
            class="size-[18px] text-slate-400 mt-0.5 motion-safe:animate-spin"
          />
          <span>CodeRabbit is already reviewing this pull request. Ask again once it has answered.</span>
        </p>

        <ul :if={not @waiting} class="space-y-4">
          <li id="coderabbit-comment" class="flex gap-3 min-w-0">
            <.icon name="pi-chat-text" class="size-[18px] text-slate-400 mt-0.5" />
            <div class="min-w-0 flex-1">
              <p class="font-semibold">Comments from {@account}</p>
              <p class="mt-0.5 text-slate-600 dark:text-slate-300">
                <code class="font-mono text-xs">{@command}</code> on the pull request. {@reads}
              </p>
            </div>
          </li>
          <li id="coderabbit-spend" class="flex gap-3 min-w-0">
            <.icon name="pi-hourglass-medium" class="size-[18px] text-slate-400 mt-0.5" />
            <div class="min-w-0 flex-1">
              <p class="font-semibold">Spends one of your CodeRabbit reviews this hour</p>
              <p class="mt-0.5 text-slate-600 dark:text-slate-300">{@spent}</p>
            </div>
          </li>
          <li :if={@show_finalize} id="coderabbit-finalize" class="flex gap-3 min-w-0">
            <.icon name="pi-arrow-u-up-left" class="size-[18px] text-slate-400 mt-0.5" />
            <div class="min-w-0 flex-1">
              <p class="font-semibold">Takes the task back to Review</p>
              <p class="mt-0.5 text-slate-600 dark:text-slate-300">
                It comes off the ready list until CodeRabbit's findings are ruled.
              </p>
            </div>
          </li>
        </ul>

        <div
          :if={@error}
          id="coderabbit-error"
          role="alert"
          class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950 px-3 py-2 text-sm text-red-800 dark:text-red-200 flex gap-2 min-w-0"
        >
          <.icon name="pi-warning-circle-bold" class="size-4 text-red-600 dark:text-red-400 mt-0.5" />
          <p class="min-w-0 break-words">{@error}</p>
        </div>

        <div class="flex justify-end gap-2 pt-1">
          <.button id="cancel-coderabbit" phx-click="close_coderabbit" phx-mounted={JS.focus()}>
            Cancel
          </.button>
          <.button
            id="confirm-coderabbit"
            data-qa="confirm_coderabbit"
            variant="primary"
            phx-click="request_coderabbit"
            data-no-repeat
            disabled={@waiting}
          >
            <.icon name="pi-rabbit" class="size-4" />Ask CodeRabbit
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp spent(0), do: "This is the pull request's first CodeRabbit review."
  defp spent(1), do: "It has had 1 review before this one."
  defp spent(count), do: "It has had #{count} reviews before this one."
end
