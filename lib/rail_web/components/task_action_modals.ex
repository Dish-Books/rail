defmodule RailWeb.Components.TaskActionModals do
  @moduledoc """
  Modal dialogues for task actions:
  - Confirmation modals: Merge, Rebase, Cleanup
  - Prompt modals: Send back with comments, Send back to Engineer, Decline Demo
  """

  use RailWeb, :html

  alias Rail.Domain.Formatters

  attr :active_modal, :map, default: nil
  attr :task, :any, default: nil
  attr :current_role_name, :string, default: nil

  def task_action_modals(assigns) do
    ~H"""
    <div
      :if={@active_modal != nil and @task != nil}
      id="task-action-dialog"
      data-qa="task-action-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <!-- 1. Confirm Merge Modal -->
      <div
        :if={@active_modal[:type] == :confirm_merge}
        id="confirm-merge-modal"
        data-qa="confirm-merge-modal"
        class="w-full max-w-[460px] rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4"
      >
        <h2 class="text-base font-semibold text-[var(--color-on-surface)]" id="confirm-merge-title">
          Merge this pull request?
        </h2>

        <div
          class="text-xs text-[var(--color-outline)] space-y-2 leading-relaxed"
          id="confirm-merge-body"
        >
          <p
            :if={@active_modal[:ignore_conflicts]}
            class="text-amber-600 dark:text-amber-400 font-medium"
          >
            GitHub last reported conflicts on this pull request. Merging asks it again; it refuses if they are still there.
          </p>
          <p>
            Squash-merges PR #{pr_number_label(@task)} and deletes its branch, then removes this task's worktree. The task and every role transcript are kept.
          </p>
        </div>

        <div class="flex justify-end space-x-3 pt-3">
          <button
            type="button"
            id="cancel-merge-button"
            data-qa="cancel-merge-button"
            phx-click="close_modal"
            class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
          >
            Cancel
          </button>

          <button
            type="button"
            id="confirm-merge-button"
            data-qa="confirm-merge-button"
            phx-click="submit_modal"
            phx-value-action="merge"
            phx-value-ignore_conflicts={to_string(@active_modal[:ignore_conflicts] || false)}
            class="px-3 py-1.5 rounded-lg bg-[var(--color-primary)] hover:bg-[var(--color-primary)]/90 text-[var(--color-on-primary)] text-xs font-semibold cursor-pointer shadow-xs"
          >
            Merge
          </button>
        </div>
      </div>

      <!-- 2. Confirm Rebase Modal -->
      <div
        :if={@active_modal[:type] == :confirm_rebase}
        id="confirm-rebase-modal"
        data-qa="confirm-rebase-modal"
        class="w-full max-w-[460px] rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4"
      >
        <h2 class="text-base font-semibold text-[var(--color-on-surface)]" id="confirm-rebase-title">
          Rebase this branch?
        </h2>

        <div
          class="text-xs text-[var(--color-outline)] space-y-2 leading-relaxed"
          id="confirm-rebase-body"
        >
          <p>
            The engineer rebases the branch onto main, resolves the conflicts and force-pushes to PR #{pr_number_label(
              @task
            )}.
          </p>
          <p>
            The task stays at "{Formatters.stage_label(@task)}" - nothing already reviewed or approved is run again.
          </p>
        </div>

        <div class="flex justify-end space-x-3 pt-3">
          <button
            type="button"
            id="cancel-rebase-button"
            data-qa="cancel-rebase-button"
            phx-click="close_modal"
            class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
          >
            Cancel
          </button>

          <button
            type="button"
            id="confirm-rebase-button"
            data-qa="confirm-rebase-button"
            phx-click="submit_modal"
            phx-value-action="rebase"
            class="px-3 py-1.5 rounded-lg bg-[var(--color-primary)] hover:bg-[var(--color-primary)]/90 text-[var(--color-on-primary)] text-xs font-semibold cursor-pointer shadow-xs"
          >
            Rebase
          </button>
        </div>
      </div>

      <!-- 3. Confirm Cleanup Modal -->
      <div
        :if={@active_modal[:type] == :confirm_cleanup}
        id="confirm-cleanup-modal"
        data-qa="confirm-cleanup-modal"
        class="w-full max-w-[460px] rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4"
      >
        <h2 class="text-base font-semibold text-[var(--color-on-surface)]" id="confirm-cleanup-title">
          Clean up this task?
        </h2>

        <p class="text-xs text-[var(--color-outline)] leading-relaxed" id="confirm-cleanup-body">
          Removes the worktree and its branch, every role transcript, and the task record. Merging does none of that - the transcripts are what Improve Roles learns from - so this is how a task you are finished with goes away. The GitHub issue and any pull request are left alone. This cannot be undone.
        </p>

        <div class="flex justify-end space-x-3 pt-3">
          <button
            type="button"
            id="cancel-cleanup-button"
            data-qa="cancel-cleanup-button"
            phx-click="close_modal"
            class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
          >
            Cancel
          </button>

          <button
            type="button"
            id="confirm-cleanup-button"
            data-qa="confirm-cleanup-button"
            phx-click="submit_modal"
            phx-value-action="cleanup"
            class="px-3 py-1.5 rounded-lg bg-red-600 hover:bg-red-500 text-white text-xs font-semibold cursor-pointer shadow-xs"
          >
            Clean up
          </button>
        </div>
      </div>

      <!-- 4. Prompt Send Back Modal -->
      <div
        :if={@active_modal[:type] == :prompt_send_back}
        id="prompt-send-back-modal"
        data-qa="prompt-send-back-modal"
        class="w-full max-w-[520px] rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4"
      >
        <h2 class="text-base font-semibold text-[var(--color-on-surface)]" id="prompt-send-back-title">
          Comment to {@active_modal[:role_name] || @current_role_name || "the agent"}
        </h2>

        <form
          id="prompt-send-back-form"
          phx-change="modal_form_change"
          phx-submit="submit_modal"
          class="space-y-4"
        >
          <input type="hidden" name="action" value="comment" />
          <div>
            <textarea
              id="send-back-comment-input"
              data-qa="send-back-comment-input"
              name="comment"
              rows="4"
              autofocus
              placeholder="What should change?"
              class="w-full rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-container)] p-3 text-xs text-[var(--color-on-surface)] placeholder:text-[var(--color-outline)] focus:border-[var(--color-primary)] focus:outline-hidden"
            ></textarea>
          </div>

          <div class="flex justify-end space-x-3 pt-2">
            <button
              type="button"
              id="cancel-send-back-button"
              data-qa="cancel-send-back-button"
              phx-click="close_modal"
              class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
            >
              Cancel
            </button>

            <button
              type="submit"
              id="submit-send-back-button"
              data-qa="submit-send-back-button"
              class="px-3 py-1.5 rounded-lg bg-[var(--color-primary)] hover:bg-[var(--color-primary)]/90 text-[var(--color-on-primary)] text-xs font-semibold cursor-pointer shadow-xs"
            >
              Send back
            </button>
          </div>
        </form>
      </div>

      <!-- 5. Prompt Send Back To Engineer Modal -->
      <div
        :if={@active_modal[:type] == :prompt_send_back_to_engineer}
        id="prompt-send-back-engineer-modal"
        data-qa="prompt-send-back-engineer-modal"
        class="w-full max-w-[520px] rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4"
      >
        <div class="space-y-1">
          <h2
            class="text-base font-semibold text-[var(--color-on-surface)]"
            id="prompt-send-back-engineer-title"
          >
            Send back to Engineer
          </h2>
          <p class="text-xs text-[var(--color-outline)]" id="prompt-send-back-engineer-subtitle">
            The findings already on this change go back with it. Add anything of your own here.
          </p>
        </div>

        <form
          id="prompt-send-back-engineer-form"
          phx-change="modal_form_change"
          phx-submit="submit_modal"
          class="space-y-4"
        >
          <input type="hidden" name="action" value="send_back_to_engineer" />
          <div>
            <textarea
              id="send-back-engineer-comment-input"
              data-qa="send-back-engineer-comment-input"
              name="comment"
              rows="4"
              autofocus
              placeholder="Optional - anything else it should do?"
              class="w-full rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-container)] p-3 text-xs text-[var(--color-on-surface)] placeholder:text-[var(--color-outline)] focus:border-[var(--color-primary)] focus:outline-hidden"
            ></textarea>
          </div>

          <div class="flex justify-end space-x-3 pt-2">
            <button
              type="button"
              id="cancel-send-back-engineer-button"
              data-qa="cancel-send-back-engineer-button"
              phx-click="close_modal"
              class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
            >
              Cancel
            </button>

            <button
              type="submit"
              id="submit-send-back-engineer-button"
              data-qa="submit-send-back-engineer-button"
              class="px-3 py-1.5 rounded-lg bg-[var(--color-primary)] hover:bg-[var(--color-primary)]/90 text-[var(--color-on-primary)] text-xs font-semibold cursor-pointer shadow-xs"
            >
              Send back
            </button>
          </div>
        </form>
      </div>

      <!-- 6. Prompt Decline Demo Modal -->
      <div
        :if={@active_modal[:type] == :prompt_decline_demo}
        id="prompt-decline-demo-modal"
        data-qa="prompt-decline-demo-modal"
        class="w-full max-w-[520px] rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] p-6 shadow-2xl space-y-4"
      >
        <div class="space-y-1">
          <h2
            class="text-base font-semibold text-[var(--color-on-surface)]"
            id="prompt-decline-demo-title"
          >
            Continue without a demo
          </h2>
          <p class="text-xs text-[var(--color-outline)]" id="prompt-decline-demo-subtitle">
            A demo will not be recorded for this task. Provide a one-line reason why (e.g. non-UI change, background refactor).
          </p>
        </div>

        <form
          id="prompt-decline-demo-form"
          phx-change="modal_form_change"
          phx-submit="submit_modal"
          class="space-y-4"
        >
          <input type="hidden" name="action" value="decline_demo" />
          <div>
            <input
              type="text"
              id="decline-demo-reason-input"
              data-qa="decline-demo-reason-input"
              name="reason"
              autofocus
              placeholder="One-line reason (e.g. non-UI change, verified in CLI)"
              class="w-full rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-container)] p-3 text-xs text-[var(--color-on-surface)] placeholder:text-[var(--color-outline)] focus:border-[var(--color-primary)] focus:outline-hidden"
            />
          </div>

          <div class="flex justify-end space-x-3 pt-2">
            <button
              type="button"
              id="cancel-decline-demo-button"
              data-qa="cancel-decline-demo-button"
              phx-click="close_modal"
              class="px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] cursor-pointer"
            >
              Cancel
            </button>

            <button
              type="submit"
              id="submit-decline-demo-button"
              data-qa="submit-decline-demo-button"
              class="px-3 py-1.5 rounded-lg bg-[var(--color-primary)] hover:bg-[var(--color-primary)]/90 text-[var(--color-on-primary)] text-xs font-semibold cursor-pointer shadow-xs"
            >
              Continue
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp pr_number_label(task) do
    if task && task.pr_number, do: "#{task.pr_number}", else: "?"
  end
end
