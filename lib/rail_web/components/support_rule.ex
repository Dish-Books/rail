defmodule RailWeb.Components.SupportRule do
  @moduledoc """
  The rule the support agent proposed that waits on the support person, in the chat box's place until they decide it.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal

  attr :proposal, LearningProposal, required: true
  attr :waiting, :integer, required: true, doc: "how many undecided rules the conversation has, this one included"
  attr :running, :boolean, required: true, doc: "whether the agent is working, which holds Approve and Reject"

  def support_rule(assigns) do
    ~H"""
    <p
      id="support-rule-hint"
      class="flex items-center gap-1.5 text-[11px] font-semibold text-amber-600 dark:text-amber-400"
    >
      <.icon name="pi-hand-pointing" class="size-3.5 shrink-0" />Approve or reject this rule to keep chatting<span :if={
        @waiting > 1
      }> · 1 of {@waiting}</span>
    </p>
    <div
      id={"support-rule-#{@proposal.id}"}
      data-qa="support-rule"
      class="rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
    >
      <div class="px-3 pt-2.5 flex flex-wrap items-center gap-2">
        <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md border text-[11px] font-semibold border-emerald-600/70 text-emerald-700 dark:text-emerald-300">
          <.icon name="pi-plus-bold" class="size-3" />New rule
        </span>
        <.learning_kind kind={@proposal.learning.kind} />
        <span class="text-[11px] text-slate-500 dark:text-slate-400">
          {Learning.roles_label(@proposal.learning)}
        </span>
      </div>
      <div class="px-3 py-2">
        <p class="text-[13px] font-medium leading-snug text-slate-900 dark:text-slate-100 break-words">
          {@proposal.learning.rule}
        </p>
        <p
          :if={@proposal.learning.why}
          class="mt-1 text-xs text-slate-600 dark:text-slate-300 break-words"
        >
          {@proposal.learning.why}
        </p>
      </div>
      <div class="px-3 pb-2.5 flex items-center justify-end gap-1.5">
        <.button
          id={"reject-rule-#{@proposal.id}"}
          size="sm"
          variant="ghost"
          disabled={@running}
          phx-click="reject_rule"
          phx-value-id={@proposal.id}
        >
          Reject
        </.button>
        <.button
          id={"approve-rule-#{@proposal.id}"}
          size="sm"
          variant="primary"
          disabled={@running}
          phx-click="approve_rule"
          phx-value-id={@proposal.id}
        >
          <.icon name="pi-check-bold" class="size-[1.1em]" />Approve
        </.button>
      </div>
    </div>
    """
  end
end
