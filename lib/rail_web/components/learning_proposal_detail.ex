defmodule RailWeb.Components.LearningProposalDetail do
  @moduledoc """
  One proposal read in full: the rules it would remove struck through above the
  rule it would make, and the sightings it rests on.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation

  attr :proposal, LearningProposal, required: true
  attr :error, :string, default: nil

  def learning_proposal_detail(assigns) do
    proposal = assigns.proposal

    {removed, kept} =
      case proposal.action do
        action when action in [:merge, :rewrite] -> {proposal.targets, nil}
        :retire -> {[proposal.learning], nil}
        :conflict -> {[], [proposal.learning | proposal.targets]}
        :promote -> {[], [proposal.learning]}
        _add_or_override -> {[], nil}
      end

    assigns =
      assigns
      |> assign(:removed, removed)
      |> assign(:kept, kept)
      |> assign(:show_draft, LearningProposal.drafts?(proposal))
      |> assign(:show_edit, proposal.action not in [:conflict])
      |> assign(:byline, calculate_byline(proposal))
      |> assign(:chip, chip_label(proposal))

    ~H"""
    <section id="proposal-detail" data-qa="proposal-detail" class="flex-1 min-w-0 flex flex-col">
      <div class="shrink-0 flex items-start gap-4 px-7 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-3">
            <span class="inline-flex items-center gap-1 shrink-0 whitespace-nowrap px-1.5 py-0.5 rounded-md border border-slate-300 dark:border-slate-600 text-slate-700 dark:text-slate-200 text-[11px] font-semibold">
              {@chip}
            </span>
            <.learning_kind kind={@proposal.learning.kind} />
            <span class="text-xs text-slate-500 dark:text-slate-400">{@byline}</span>
          </div>
          <h2
            id="proposal-title"
            class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100 break-words"
          >
            {@proposal.title || @proposal.learning.rule}
          </h2>
        </div>
        <div class="shrink-0 flex gap-2">
          <.button
            size="sm"
            variant="ghost"
            id="reject-proposal-button"
            phx-click="reject_proposal"
            phx-value-id={@proposal.id}
          >
            Reject
          </.button>
          <.button :if={@show_edit} size="sm" id="edit-proposal-button" phx-click="edit_learning">
            <.icon name="pi-pencil-simple" class="size-[1.1em]" />Edit
          </.button>
          <.button
            size="sm"
            variant="primary"
            id="approve-proposal-button"
            phx-click="approve_proposal"
            phx-value-id={@proposal.id}
          >
            <.icon name="pi-check-bold" class="size-[1.1em]" />Approve
          </.button>
        </div>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-7 py-5 space-y-4 max-w-[1000px]">
        <p :if={@error} id="learnings-error" class="text-xs text-red-600 dark:text-red-500">
          {@error}
        </p>

        <ul
          id="proposal-rules"
          class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-700"
        >
          <li
            :for={rule <- @removed}
            data-qa="proposal-removed"
            class="flex items-start gap-2 px-3 py-2"
          >
            <.icon name="pi-minus-circle" class="mt-0.5 size-4 text-red-500" />
            <span class="min-w-0 flex-1">
              <span class="block text-[13px] text-slate-600 dark:text-slate-400 line-through decoration-slate-500 break-words">
                {rule.rule}
              </span>
              <span class="block text-[11px] text-slate-500">{rule_note(rule)}</span>
            </span>
          </li>
          <li
            :for={rule <- @kept || []}
            data-qa="proposal-subject"
            class="flex items-start gap-2 px-3 py-2.5"
          >
            <.icon
              name={if @proposal.action == :conflict, do: "pi-arrows-left-right", else: "pi-circle"}
              class="mt-0.5 size-4 text-slate-400"
            />
            <span class="min-w-0 flex-1">
              <span class="block text-[13.5px] font-medium text-slate-900 dark:text-slate-100 break-words">
                {rule.rule}
              </span>
              <span class="block text-[11px] text-slate-500 dark:text-slate-400">{rule_note(rule)}</span>
            </span>
          </li>
          <li
            :if={@show_draft}
            data-qa="proposal-draft"
            class="flex items-start gap-2 px-3 py-2.5 bg-emerald-50 dark:bg-emerald-950/20"
          >
            <.icon name="pi-plus-circle" class="mt-0.5 size-4 text-emerald-500" />
            <span class="min-w-0 flex-1">
              <span class="block text-[13.5px] font-medium text-slate-900 dark:text-slate-100 break-words">
                {@proposal.learning.rule}
              </span>
              <span class="block text-[11px] text-slate-500 dark:text-slate-400">
                {Learning.roles_label(@proposal.learning)}<span :if={@proposal.learning.path_glob}> · <span class="font-mono">{@proposal.learning.path_glob}</span></span>
              </span>
              <span
                :if={@proposal.learning.why}
                phx-no-format
                class="mt-1.5 block text-xs text-slate-600 dark:text-slate-300 whitespace-pre-wrap break-words"
              >{@proposal.learning.why}</span>
            </span>
          </li>
        </ul>

        <p
          :if={@proposal.action == :promote}
          id="proposal-promote"
          class="text-xs text-slate-600 dark:text-slate-300"
        >
          Approving opens an issue to make this {LearningProposal.promote_label(
            @proposal.promote_to || :claude_md
          )}. The rule is retired once that issue is done.
        </p>

        <div :if={@proposal.evidence != []} id="proposal-evidence">
          <p class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            Evidence · {length(@proposal.evidence)}
          </p>
          <ul>
            <li
              :for={observation <- @proposal.evidence}
              class="flex items-center gap-2 py-1.5 text-xs min-w-0"
            >
              <.icon name="pi-chat-centered-text" class="size-3.5 text-slate-400" />
              <span class="font-mono text-slate-500 dark:text-slate-400 w-16 shrink-0 truncate">
                {calculate_where(observation)}
              </span>
              <span class="truncate text-slate-700 dark:text-slate-300">
                {Observation.source_label(observation.source_kind)}: “{observation.text}”, {Observation.actor_label(
                  observation
                )}
              </span>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp chip_label(%LearningProposal{action: :merge, target_ids: ids}), do: "Merge #{length(ids)}"
  defp chip_label(%LearningProposal{action: action}), do: LearningProposal.action_label(action)

  defp calculate_byline(%LearningProposal{curator_pass: %{started_at: at}}),
    do: "Curator, #{Calendar.strftime(at, "%b %-d %H:%M")}"

  defp calculate_byline(%LearningProposal{summary: summary}) when is_binary(summary), do: summary
  defp calculate_byline(%LearningProposal{}), do: ""

  defp rule_note(%Learning{status: :provisional}), do: "Provisional"

  defp rule_note(%Learning{} = rule) do
    who =
      cond do
        rule.auto -> "Auto"
        rule.approved_by -> rule.approved_by.name
        true -> Learning.status_label(rule.status)
      end

    "#{who} · #{rule.run_count} runs"
  end

  defp calculate_where(%Observation{task: %{issue: %{identifier: identifier}}}), do: identifier

  defp calculate_where(%Observation{source_url: url}) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_match, number] -> "PR ##{number}"
      nil -> "GitHub"
    end
  end

  defp calculate_where(%Observation{}), do: ""
end
