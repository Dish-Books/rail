defmodule RailWeb.Components.TaskLearnings do
  @moduledoc """
  A task's Learnings item: the curator's proposals for it, each with an Approve and Reject toggle the person can
  change until the task merges, which carries out what they chose. Empty states cover the curator reading, finding
  nothing and failing.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal

  attr :proposals, :list, required: true
  attr :run_state, :atom, required: true, doc: "the curator run's `Run.state/1`"
  attr :errors, :map, default: %{}, doc: "a proposal id to the message its last click got"
  attr :target, :any, required: true

  def task_learnings(assigns) do
    total = length(assigns.proposals)
    pending = Enum.count(assigns.proposals, &LearningProposal.undecided?/1)

    assigns =
      assigns
      |> assign(:count, "#{total} #{if total == 1, do: "proposal", else: "proposals"} · #{pending} to decide")
      |> assign(:show_empty, assigns.proposals == [])
      |> assign(:empty, empty_copy(assigns.run_state))

    ~H"""
    <section id="task-learnings" data-qa="task-learnings" class="flex-1 min-w-0 min-h-0 flex flex-col">
      <div class="shrink-0 flex items-center gap-3 px-6 py-3 border-b border-slate-200 dark:border-slate-700">
        <h2 class="text-[15px] font-semibold text-slate-900 dark:text-slate-100">Learnings</h2>
        <span id="task-learnings-count" class="text-[13px] text-slate-500 dark:text-slate-400">{@count}</span>
        <.link
          navigate={~p"/learnings"}
          class="ml-auto inline-flex items-center gap-1 text-[13px] text-blue-600 dark:text-blue-400 hover:underline rounded-sm focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-lightbulb" class="size-4" />All learnings
        </.link>
      </div>
      <div class="flex-1 min-h-0 overflow-y-auto px-6 py-5 space-y-3 max-w-[960px]">
        <div
          :if={@show_empty}
          id="task-learnings-empty"
          class="flex flex-col items-center text-center max-w-md mx-auto py-14"
        >
          <div class="grid place-items-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
            <.icon name="pi-lightbulb" class="size-7" />
          </div>
          <p class="mt-4 text-[15px] font-semibold text-slate-900 dark:text-slate-100">
            {elem(@empty, 0)}
          </p>
          <p class="mt-1 text-[13px] text-slate-500 dark:text-slate-400">{elem(@empty, 1)}</p>
        </div>
        <article
          :for={proposal <- @proposals}
          id={"proposal-#{proposal.id}"}
          data-qa="task-proposal"
          class={[
            "rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900",
            proposal.status != :pending && "opacity-80"
          ]}
        >
          <div class="flex items-start gap-3 px-4 pt-3 pb-2">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class={[
                  "inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md border text-[11px] font-semibold",
                  chip_class(proposal.action)
                ]}>
                  <.icon name={chip_icon(proposal.action)} class="size-3" />{chip_label(
                    proposal.action
                  )}
                </span>
                <.learning_kind kind={proposal.learning.kind} />
              </div>
              <h3 class="mt-1.5 text-[14px] font-semibold text-slate-900 dark:text-slate-100 break-words">
                {proposal.title || proposal.learning.rule}
              </h3>
            </div>
            <div class="shrink-0 flex items-center gap-1.5">
              <span
                :if={proposal.status == :pending and proposal.choice}
                data-qa="proposal-choice"
                class="text-[12px] text-slate-500 dark:text-slate-400"
              >
                {chosen_label(proposal)}
              </span>
              <.button
                :if={proposal.status == :pending}
                id={"reject-proposal-#{proposal.id}"}
                size="sm"
                variant={if proposal.choice == :rejected, do: "secondary", else: "ghost"}
                aria-pressed={to_string(proposal.choice == :rejected)}
                phx-click="reject_proposal"
                phx-value-id={proposal.id}
                phx-target={@target}
              >
                <.icon :if={proposal.choice == :rejected} name="pi-x-bold" class="size-[1.1em]" />Reject
              </.button>
              <.button
                :if={proposal.status == :pending}
                id={"approve-proposal-#{proposal.id}"}
                size="sm"
                variant={approve_variant(proposal.choice)}
                aria-pressed={to_string(proposal.choice == :approved)}
                phx-click="approve_proposal"
                phx-value-id={proposal.id}
                phx-target={@target}
              >
                <.icon name="pi-check-bold" class="size-[1.1em]" />Approve
              </.button>
              <span
                :if={proposal.status == :approved}
                data-qa="proposal-approved"
                class="inline-flex items-center gap-1 text-[12px] font-semibold text-emerald-700 dark:text-emerald-400"
              >
                <.icon name="pi-check-circle-fill" class="size-4" />{decided_label(
                  "Approved",
                  proposal
                )}
              </span>
              <span
                :if={proposal.status == :rejected}
                data-qa="proposal-rejected"
                class="inline-flex items-center gap-1 text-[12px] font-semibold text-slate-500 dark:text-slate-400"
              >
                <.icon name="pi-x-circle-fill" class="size-4" />{decided_label("Rejected", proposal)}
              </span>
            </div>
          </div>
          <div class="px-4 pb-3">
            <ul class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-700 overflow-hidden">
              <li
                :for={rule <- removed(proposal)}
                data-qa="proposal-removed"
                class="flex items-start gap-2 px-3 py-2"
              >
                <.icon name="pi-minus-circle" class="mt-0.5 size-4 shrink-0 text-red-500" />
                <span class="min-w-0 flex-1 text-[13px] text-slate-600 dark:text-slate-400 line-through decoration-slate-500 break-words">
                  {rule.rule}
                </span>
              </li>
              <li
                :if={LearningProposal.drafts?(proposal)}
                data-qa="proposal-draft"
                class="flex items-start gap-2 px-3 py-2.5 bg-emerald-50 dark:bg-emerald-950/20"
              >
                <.icon name="pi-plus-circle" class="mt-0.5 size-4 shrink-0 text-emerald-500" />
                <span class="min-w-0 flex-1">
                  <span class="block text-[13.5px] font-medium text-slate-900 dark:text-slate-100 break-words">
                    {proposal.learning.rule}
                  </span>
                  <span class="mt-0.5 block text-[11px] text-slate-500 dark:text-slate-400 break-words">
                    {Learning.roles_label(proposal.learning)}<span :if={proposal.learning.path_glob}> · <span class="font-mono">{proposal.learning.path_glob}</span></span>
                  </span>
                  <span
                    :if={proposal.status == :pending and proposal.learning.why}
                    class="mt-1.5 block text-xs text-slate-600 dark:text-slate-300 break-words"
                  >
                    {proposal.learning.why}
                  </span>
                </span>
              </li>
              <li
                :if={proposal.action == :retire and proposal.status == :pending and proposal.summary}
                data-qa="proposal-summary"
                class="px-3 py-2 text-xs text-slate-600 dark:text-slate-300 break-words"
              >
                {proposal.summary}
              </li>
            </ul>
            <p
              :if={@errors[proposal.id]}
              data-qa="task-proposal-error"
              role="alert"
              class="mt-2 text-xs text-red-600 dark:text-red-400"
            >
              {@errors[proposal.id]}
            </p>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp removed(%LearningProposal{action: :rewrite, targets: targets}), do: targets
  defp removed(%LearningProposal{action: :retire, learning: learning}), do: [learning]
  defp removed(%LearningProposal{}), do: []

  defp chip_label(:add), do: "New"
  defp chip_label(:rewrite), do: "Rewrite"
  defp chip_label(:retire), do: "Retire"

  defp chip_icon(:add), do: "pi-plus-bold"
  defp chip_icon(:rewrite), do: "pi-pencil-simple-bold"
  defp chip_icon(:retire), do: "pi-archive-bold"

  defp chip_class(:add), do: "border-emerald-600/70 text-emerald-700 dark:text-emerald-300"
  defp chip_class(:rewrite), do: "border-sky-600/70 text-sky-700 dark:text-sky-300"
  defp chip_class(:retire), do: "border-slate-400 dark:border-slate-500 text-slate-700 dark:text-slate-300"

  # Nothing chosen yet is the call to Approve; once something is, the choice is the one filled in.
  defp approve_variant(nil), do: "primary"
  defp approve_variant(:approved), do: "success"
  defp approve_variant(:rejected), do: "ghost"

  defp chosen_label(%LearningProposal{choice: :approved} = proposal),
    do: decided_label("Approved", proposal) <> " · applies on merge"

  defp chosen_label(%LearningProposal{choice: :rejected} = proposal),
    do: decided_label("Rejected", proposal) <> " · final on merge"

  # The daily pass approves, and a retired rule rejects, with nobody's name on it.
  defp decided_label(verb, %LearningProposal{decided_by: %{name: name}}) when is_binary(name) and name != "",
    do: "#{verb} by #{name}"

  defp decided_label(verb, %LearningProposal{decided_by: %{login: login}}) when is_binary(login),
    do: "#{verb} by #{login}"

  defp decided_label(verb, %LearningProposal{}), do: verb

  defp empty_copy(state) when state in [:running, :waiting],
    do: {"The curator is reading this task", "Its proposals show here as it saves them."}

  defp empty_copy(:failed),
    do: {"No proposals yet", "The curator stopped before saving any. Retry it from the conversation."}

  defp empty_copy(_done_or_stopped),
    do:
      {"No proposals",
       "The curator found nothing on this task worth a rule. Ask it in the conversation if you saw something."}
end
