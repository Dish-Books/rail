defmodule RailWeb.Components.LearningsQueue do
  @moduledoc """
  The left pane of the Learnings page: the counted segments, search and filters, and the rules or proposals in one segment.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal

  attr :status, :atom, required: true
  attr :counts, :map, required: true
  attr :learnings, :list, default: []
  attr :proposals, :list, default: []
  attr :query, :string, default: ""
  attr :kind, :atom, default: nil
  attr :role, :atom, default: nil
  attr :auto, :boolean, default: false
  attr :week, :boolean, default: false
  attr :open_menu, :atom, default: nil
  attr :selected_id, :string, default: nil
  attr :params, :list, required: true, doc: "the queue's URL params, kept on every card's link"
  attr :search_unavailable, :boolean, default: false
  attr :project_name, :string, default: nil
  attr :show_projects, :boolean, default: false

  attr :digest, :map,
    default: nil,
    doc: "`%{channel:, permalink:}` for the footer link, `channel` nil where it posts nowhere"

  slot :digest_picker, doc: "replaces the read-only digest link, for those who may change the channel"

  def learnings_queue(assigns) do
    assigns =
      assigns
      |> assign(:segments, [
        {:review, "To review", assigns.counts.review},
        {:active, "Active", assigns.counts.active},
        {:provisional, "Provisional", assigns.counts.provisional},
        {:retired, "Retired", assigns.counts.retired}
      ])
      |> assign(:kind_label, if(assigns.kind, do: Learning.kind_label(assigns.kind), else: "Any kind"))
      |> assign(:role_label, if(assigns.role, do: Learning.role_label(assigns.role), else: "Any role"))
      |> assign(:match_line, calculate_match_line(assigns))
      |> assign(:empty, calculate_empty(assigns))
      |> assign(
        :show_digest,
        assigns.digest_picker == [] and is_map(assigns.digest) and is_binary(assigns.digest.channel)
      )

    ~H"""
    <aside
      id="learnings-queue"
      data-qa="learnings-queue"
      class="w-[420px] max-xl:w-[340px] shrink-0 flex flex-col border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <div class="px-4 pt-4 pb-3 space-y-2.5 border-b border-slate-200 dark:border-slate-700">
        <div id="learnings-segments" class="flex rounded-lg bg-slate-100 dark:bg-slate-800 p-0.5">
          <button
            :for={{status, label, count} <- @segments}
            type="button"
            id={"learnings-segment-#{status}"}
            phx-click="status"
            phx-value-status={status}
            aria-pressed={to_string(@status == status)}
            class={[
              "flex-auto px-1.5 py-1 rounded-md text-[11.5px] font-semibold whitespace-nowrap cursor-pointer",
              @status == status &&
                "bg-white dark:bg-slate-700 text-slate-900 dark:text-slate-100 shadow-xs",
              @status != status &&
                "text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
            ]}
          >
            {label}
            <span :if={status == :review} class="text-amber-600 dark:text-amber-400">{calculate_count(
              count
            )}</span>
            <span :if={status != :review}>{calculate_count(count)}</span>
          </button>
        </div>

        <form id="learnings-search-form" class="relative" phx-change="search" phx-submit="search">
          <.icon
            name="pi-magnifying-glass"
            class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-slate-400"
          />
          <input
            type="search"
            id="learnings-search"
            name="q"
            value={@query}
            phx-debounce="300"
            autocomplete="off"
            placeholder="Search rules the way agents do"
            class="w-full pl-8 pr-3 py-1.5 text-[13px] rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-500"
          />
        </form>

        <div class="flex flex-wrap items-center gap-1.5">
          <div class="relative" phx-click-away={@open_menu == :kind && "close_menu"}>
            <button
              type="button"
              id="learnings-kind-menu"
              phx-click="toggle_menu"
              phx-value-menu="kind"
              aria-expanded={to_string(@open_menu == :kind)}
              class={[chip(@kind != nil), "cursor-pointer"]}
            >
              {@kind_label}<.icon name="pi-caret-down" class="size-3" />
            </button>
            <div
              :if={@open_menu == :kind}
              id="learnings-kind-options"
              phx-window-keydown="close_menu"
              phx-key="Escape"
              class="absolute left-0 mt-1 w-44 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 p-1 shadow-xl z-30"
            >
              <button
                :for={
                  {value, label} <- [
                    {"", "Any kind"} | Enum.map(Learning.kinds(), &{&1, Learning.kind_label(&1)})
                  ]
                }
                type="button"
                id={"learnings-kind-#{if value == "", do: "any", else: value}"}
                phx-click="filter_kind"
                phx-value-kind={value}
                class="block w-full text-left px-2.5 py-1.5 rounded-md text-xs text-slate-800 dark:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-700 cursor-pointer"
              >
                {label}
              </button>
            </div>
          </div>

          <div class="relative" phx-click-away={@open_menu == :role && "close_menu"}>
            <button
              type="button"
              id="learnings-role-menu"
              phx-click="toggle_menu"
              phx-value-menu="role"
              aria-expanded={to_string(@open_menu == :role)}
              class={[chip(@role != nil), "cursor-pointer"]}
            >
              {@role_label}<.icon name="pi-caret-down" class="size-3" />
            </button>
            <div
              :if={@open_menu == :role}
              id="learnings-role-options"
              phx-window-keydown="close_menu"
              phx-key="Escape"
              class="absolute left-0 mt-1 w-44 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 p-1 shadow-xl z-30"
            >
              <button
                :for={
                  {value, label} <- [
                    {"", "Any role"} | Enum.map(Learning.roles(), &{&1, Learning.role_label(&1)})
                  ]
                }
                type="button"
                id={"learnings-role-#{if value == "", do: "any", else: value}"}
                phx-click="filter_role"
                phx-value-role={value}
                class="block w-full text-left px-2.5 py-1.5 rounded-md text-xs text-slate-800 dark:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-700 cursor-pointer"
              >
                {label}
              </button>
            </div>
          </div>

          <button
            type="button"
            id="learnings-auto"
            phx-click="toggle_auto"
            aria-pressed={to_string(@auto)}
            class={[chip(@auto), "cursor-pointer"]}
          >
            Auto
          </button>
          <button
            type="button"
            id="learnings-week"
            phx-click="toggle_week"
            aria-pressed={to_string(@week)}
            class={[chip(@week), "cursor-pointer"]}
          >
            Activated this week
          </button>
        </div>
      </div>

      <p id="learnings-match-line" class="px-4 pt-2.5 text-[11px] text-slate-500 dark:text-slate-400">
        {@match_line}
      </p>

      <div id="learnings-list" class="flex-1 min-h-0 overflow-y-auto p-2 space-y-1">
        <.empty_state :if={@empty} empty={@empty} query={@query} project_name={@project_name} />

        <.link
          :for={learning <- @learnings}
          patch={~p"/learnings/#{learning.id}?#{@params}"}
          id={"learning-card-#{learning.id}"}
          data-qa="learning-card"
          aria-current={if learning.id == @selected_id, do: "true"}
          class={card_class(learning.id == @selected_id)}
        >
          <span class="flex items-center gap-2 min-w-0 text-[11px]">
            <.learning_kind kind={learning.kind} />
            <.learning_status learning={learning} flagged={learning.flagged} />
            <.project_badge :if={@show_projects} project={learning.project} />
            <span class="ml-auto shrink-0 font-mono text-slate-500 dark:text-slate-400">
              {calculate_date(learning.retired_at || learning.activated_at || learning.inserted_at)}
            </span>
          </span>
          <span class={rule_class(learning.id == @selected_id)}>{learning.rule}</span>
          <span class="mt-1 flex items-center gap-2 min-w-0 text-[11px] text-slate-500 dark:text-slate-400">
            <span class="truncate min-w-0">
              {Learning.roles_label(learning)}<span :if={learning.path_glob}> · <span class="font-mono">{learning.path_glob}</span></span>
            </span>
            <span class="ml-auto shrink-0 whitespace-nowrap">
              {calculate_plural(learning.run_count, "run", "runs")}<span :if={
                learning.suppressed_count > 0
              }> · {learning.suppressed_count} suppressed</span><span
                :if={learning.broken_count > 0}
                class="text-red-600 dark:text-red-400"
              > · {learning.broken_count} broken</span>
            </span>
          </span>
        </.link>

        <.link
          :for={proposal <- @proposals}
          patch={proposal_path(proposal, @params)}
          id={"proposal-card-#{proposal.id}"}
          data-qa="proposal-card"
          aria-current={if proposal_key(proposal) == @selected_id, do: "true"}
          class={card_class(proposal_key(proposal) == @selected_id)}
        >
          <span class="flex items-center gap-2 min-w-0">
            <.proposal_chip proposal={proposal} />
            <.learning_kind kind={proposal.learning.kind} />
            <.project_badge :if={@show_projects} project={proposal.project} />
          </span>
          <span class={rule_class(proposal_key(proposal) == @selected_id)}>{proposal.learning.rule}</span>
          <span
            :if={proposal.summary || proposal.title}
            class="mt-1 block truncate text-[11px] text-slate-500 dark:text-slate-400"
          >
            {proposal.summary || proposal.title}
          </span>
        </.link>
      </div>

      <div class="px-4 py-2.5 border-t border-slate-200 dark:border-slate-700 flex items-center gap-2 min-w-0">
        <.button size="sm" id="add-learning-button" phx-click="new_learning">
          <.icon name="pi-plus-circle-fill" class="size-[1.1em]" />Add rule
        </.button>
        {render_slot(@digest_picker)}
        <.link
          :if={@show_digest and is_binary(@digest.permalink)}
          href={@digest.permalink}
          target="_blank"
          rel="noopener"
          id="learnings-digest-link"
          title="Open today's curator digest in Slack"
          class="ml-auto min-w-0 inline-flex items-center gap-1 whitespace-nowrap text-[11px] text-slate-500 dark:text-slate-400 hover:underline"
        >
          06:00 digest in
          <span class="truncate font-mono font-semibold text-blue-600 dark:text-blue-400">#{@digest.channel}</span>
          <.icon name="pi-arrow-square-out" class="size-3 text-blue-600 dark:text-blue-400" />
        </.link>
        <span
          :if={@show_digest and is_nil(@digest.permalink)}
          id="learnings-digest-link"
          class="ml-auto min-w-0 inline-flex items-center gap-1 whitespace-nowrap text-[11px] text-slate-500 dark:text-slate-400"
        >
          06:00 digest in
          <span class="truncate font-mono font-semibold text-slate-600 dark:text-slate-300">#{@digest.channel}</span>
        </span>
      </div>
    </aside>
    """
  end

  attr :empty, :atom, required: true
  attr :query, :string, required: true
  attr :project_name, :string, default: nil

  defp empty_state(%{empty: :no_rules} = assigns) do
    ~H"""
    <.empty_box id="learnings-empty" icon="pi-brain-fill">
      <:title>
        {if @project_name, do: "No rules in #{@project_name} yet", else: "No rules yet"}
      </:title>
      They arrive as tasks finish and the curator runs.
    </.empty_box>
    """
  end

  defp empty_state(%{empty: :no_match} = assigns) do
    ~H"""
    <.empty_box id="learnings-empty" icon="pi-magnifying-glass">
      <:title>No rules match “{@query}”</:title>
      Try fewer words, or another status.
    </.empty_box>
    """
  end

  defp empty_state(%{empty: :nothing_to_review} = assigns) do
    ~H"""
    <.empty_box id="learnings-empty" icon="pi-check-circle-fill">
      <:title>Nothing to review</:title>
      The curator runs at 06:00.
    </.empty_box>
    """
  end

  defp empty_state(%{empty: :filtered} = assigns) do
    ~H"""
    <.empty_box id="learnings-empty" icon="pi-funnel-simple">
      <:title>No rules match these filters</:title>
      Try fewer filters, or another status.
    </.empty_box>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  slot :title, required: true
  slot :inner_block, required: true

  defp empty_box(assigns) do
    ~H"""
    <div
      id={@id}
      class="m-2 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-8 text-center"
    >
      <.icon name={@icon} class="size-10 text-slate-400 dark:text-slate-500" />
      <p class="mt-2 text-sm font-semibold text-slate-700 dark:text-slate-300 break-words">
        {render_slot(@title)}
      </p>
      <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :proposal, LearningProposal, required: true

  defp proposal_chip(assigns) do
    assigns = assign(assigns, :label, chip_label(assigns.proposal))

    ~H"""
    <span
      data-qa="proposal-action"
      class={[
        "inline-flex items-center gap-1 shrink-0 whitespace-nowrap px-1.5 py-0.5 rounded-md border text-[11px] font-semibold",
        @proposal.action == :override && "border-amber-400/60 text-amber-700 dark:text-amber-300",
        @proposal.action != :override &&
          "border-slate-300 dark:border-slate-600 text-slate-700 dark:text-slate-200"
      ]}
    >
      <.icon name={action_icon(@proposal.action)} class="size-3" />{@label}
    </span>
    """
  end

  defp calculate_match_line(%{search_unavailable: true}), do: "Search is unavailable right now"
  defp calculate_match_line(%{status: :review, proposals: proposals}), do: "#{length(proposals)} to review, oldest first"

  defp calculate_match_line(%{query: query, learnings: learnings}) when query != "",
    do: "#{calculate_plural(length(learnings), "match", "matches")}, best first"

  defp calculate_match_line(%{status: status, learnings: learnings, counts: counts} = assigns) do
    shown = length(learnings)
    total = Map.fetch!(counts, status)
    word = String.downcase(Learning.status_label(status))

    if shown < total and not filtered?(assigns),
      do: "Newest #{calculate_count(shown)} of #{calculate_count(total)} #{word}",
      else: "#{calculate_count(shown)} #{word}, newest first"
  end

  defp calculate_empty(%{status: :review, proposals: []}), do: :nothing_to_review
  defp calculate_empty(%{status: :review}), do: nil
  defp calculate_empty(%{search_unavailable: true}), do: nil
  defp calculate_empty(%{learnings: [_first | _rest]}), do: nil
  defp calculate_empty(%{query: query}) when query != "", do: :no_match

  defp calculate_empty(%{counts: counts} = assigns) do
    if counts.active + counts.provisional + counts.retired == 0 and not filtered?(assigns),
      do: :no_rules,
      else: :filtered
  end

  defp filtered?(assigns), do: assigns.kind != nil or assigns.role != nil or assigns.auto or assigns.week

  # An override is read on the rule it flags, so its card opens the rule.
  defp proposal_path(%LearningProposal{action: :override, learning_id: id}, params), do: ~p"/learnings/#{id}?#{params}"
  defp proposal_path(%LearningProposal{id: id}, params), do: ~p"/learnings/proposals/#{id}?#{params}"

  defp proposal_key(%LearningProposal{action: :override, learning_id: id}), do: id
  defp proposal_key(%LearningProposal{id: id}), do: id

  defp chip_label(%LearningProposal{action: :merge, target_ids: ids}), do: "Merge #{length(ids)}"
  defp chip_label(%LearningProposal{action: action}), do: LearningProposal.action_label(action)

  defp action_icon(:add), do: "pi-plus"
  defp action_icon(:merge), do: "pi-git-merge"
  defp action_icon(:rewrite), do: "pi-pencil-simple"
  defp action_icon(:retire), do: "pi-archive"
  defp action_icon(:conflict), do: "pi-arrows-left-right"
  defp action_icon(:promote), do: "pi-arrow-fat-line-up"
  defp action_icon(:override), do: "pi-flag"

  defp chip(true),
    do:
      "inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"

  defp chip(false),
    do:
      "inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap bg-slate-200 dark:bg-slate-700 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-600"

  defp card_class(true), do: "block rounded-xl px-3 py-2.5 bg-white dark:bg-slate-800 ring-1 ring-blue-500"
  defp card_class(false), do: "block rounded-xl px-3 py-2.5 hover:bg-slate-100 dark:hover:bg-slate-800/70"

  defp rule_class(true),
    do: "mt-1 block text-[13px] leading-snug line-clamp-2 break-words font-semibold text-slate-900 dark:text-slate-100"

  defp rule_class(false),
    do: "mt-1 block text-[13px] leading-snug line-clamp-2 break-words font-medium text-slate-800 dark:text-slate-200"

  defp calculate_date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")

  defp calculate_plural(1, one, _many), do: "1 #{one}"
  defp calculate_plural(count, _one, many), do: "#{calculate_count(count)} #{many}"

  # Thousands are grouped, as the segments read in the design: 1,284.
  defp calculate_count(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
