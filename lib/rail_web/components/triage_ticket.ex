defmodule RailWeb.Components.TriageTicket do
  @moduledoc """
  One proposed ticket or follow-up, edited in place and sent by the thread's one button, or ignored.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Triage.Schemas.Item
  alias RailWeb.Components.TriageVerdict

  attr :item, Item, required: true
  attr :locked, :boolean, required: true, doc: "the agent is working or the thread was dismissed"

  def triage_ticket(assigns) do
    item = assigns.item
    closed = Item.closed?(item)
    readonly = assigns.locked or closed
    show_fields = is_nil(item.existing_issue_id)

    assigns =
      assigns
      |> assign(:readonly, readonly)
      |> assign(:show_fields, show_fields)
      |> assign(:show_kind_select, show_fields and not readonly)
      |> assign(:show_followup, is_struct(item.existing_issue, Issue))
      |> assign(:show_created, is_struct(item.created_issue, Issue))
      |> assign(:show_commented, is_struct(item.followup_posted_at, DateTime) and is_struct(item.sent_at, DateTime))
      |> assign(:show_ignore, not closed)
      |> assign(:ignored_label, if(show_fields, do: "Ignored · not created", else: "Ignored · not added"))
      |> assign(:verdict, Item.fitting_verdict(item))
      |> assign(:kind_style, TriageVerdict.kind_style(item.kind))
      |> assign(:kinds, Enum.map(Item.kinds(), &{Item.kind_label(&1), &1}))
      |> assign(:priorities, [{"No priority", ""} | Enum.map(Issue.priorities(), &{Issue.priority_label(&1), &1})])
      |> assign(:estimates, [{"No estimate", ""} | Enum.map(Item.estimates(), &{estimate_label(&1), &1})])

    ~H"""
    <article
      id={"triage-ticket-#{@item.id}"}
      data-qa="triage-ticket"
      data-ignored={to_string(@item.ignored)}
      class={[
        "rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900",
        @item.ignored && "opacity-55"
      ]}
    >
      <form id={"triage-ticket-form-#{@item.id}"} phx-change="update_item">
        <input type="hidden" name="item_id" value={@item.id} />
        <header class="flex flex-wrap items-center gap-x-2.5 gap-y-1.5 px-4 pt-3 pb-2 min-w-0">
          <span class="flex items-center justify-center h-5 w-5 shrink-0 rounded-full bg-slate-200 dark:bg-slate-700 text-[11px] font-bold text-slate-900 dark:text-slate-100">
            {@item.position}
          </span>
          <span :if={@show_kind_select} class="relative inline-flex items-center shrink-0">
            <select
              id={"triage-ticket-kind-#{@item.id}"}
              name="item[kind]"
              aria-label="Kind"
              class={[
                "appearance-none field-sizing-content pl-6 pr-6 py-0.5 rounded text-[11px] font-bold uppercase tracking-wider border-0 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500",
                @kind_style.class
              ]}
            >
              {Phoenix.HTML.Form.options_for_select(@kinds, @item.kind)}
            </select>
            <.icon name={@kind_style.icon} class="size-3 absolute left-1.5 pointer-events-none" />
            <.icon name="pi-caret-down" class="size-2.5 absolute right-1.5 pointer-events-none" />
          </span>
          <.triage_verdict :if={!@show_kind_select} kind={@item.kind} />
          <h3
            :if={@show_followup}
            class="min-w-0 text-sm font-semibold truncate text-slate-900 dark:text-slate-100"
          >
            Follow up on {@item.existing_issue.identifier}
          </h3>
          <input
            :if={@show_fields}
            id={"triage-ticket-title-#{@item.id}"}
            name="item[issue_title]"
            value={@item.issue_title}
            aria-label="Title"
            placeholder="Untitled, so it is not created"
            phx-debounce="400"
            readonly={@readonly}
            class="min-w-0 flex-1 basis-40 px-2 py-1 -ml-2 text-sm font-semibold rounded-md border border-transparent hover:border-slate-300 dark:hover:border-slate-600 focus:border-slate-400 dark:focus:border-slate-500 bg-transparent text-slate-900 dark:text-slate-100 placeholder-slate-400 truncate"
          />
          <.triage_verdict
            :if={@verdict}
            id={"triage-ticket-verdict-#{@item.id}"}
            kind={@item.kind}
            verdict={@verdict}
          />
          <span class="ml-auto flex items-center gap-3 shrink-0">
            <.created :if={@show_created} item_id={@item.id} issue={@item.created_issue} />
            <span
              :if={@show_commented}
              id={"triage-ticket-commented-#{@item.id}"}
              class="inline-flex items-center gap-1 text-[11px] font-semibold whitespace-nowrap text-emerald-600 dark:text-emerald-400"
            >
              <.icon name="pi-check-circle-fill" class="size-3.5" />Comment added to {@item.existing_issue.identifier}
            </span>
            <span
              :if={@item.ignored}
              id={"triage-ticket-ignored-#{@item.id}"}
              class="text-[11px] font-semibold whitespace-nowrap text-slate-500 dark:text-slate-400"
            >
              {@ignored_label}
            </span>
            <button
              :if={@show_ignore}
              type="button"
              role="switch"
              aria-checked={to_string(@item.ignored)}
              aria-label={"Ignore item #{@item.position}"}
              id={"triage-ticket-ignore-#{@item.id}"}
              phx-click="toggle_ignore"
              phx-value-item_id={@item.id}
              disabled={@locked}
              class={[
                "inline-flex items-center gap-1.5 text-[11px] font-semibold rounded focus-visible:outline-2 focus-visible:outline-blue-500 disabled:opacity-50 disabled:cursor-not-allowed",
                @item.ignored && "text-slate-800 dark:text-slate-200",
                !@item.ignored && "text-slate-500 dark:text-slate-400"
              ]}
            >
              <span class={[
                "relative inline-flex h-4 w-7 rounded-full",
                @item.ignored && "bg-slate-500 dark:bg-slate-300",
                !@item.ignored && "bg-slate-300 dark:bg-slate-600"
              ]}>
                <span class={[
                  "absolute top-0.5 h-3 w-3 rounded-full",
                  @item.ignored && "left-3.5 bg-white dark:bg-slate-900",
                  !@item.ignored && "left-0.5 bg-white"
                ]}></span>
              </span>
              Ignore
            </button>
          </span>
        </header>
        <div :if={@show_followup} class="px-4 pb-4 space-y-2">
          <p class="flex flex-wrap items-center gap-x-2 min-w-0 text-[12.5px] text-slate-800 dark:text-slate-200">
            <.icon name="pi-link" class="size-3.5 shrink-0 text-slate-400" />
            <span class="font-semibold whitespace-nowrap">Already tracked in</span>
            <.link
              navigate={~p"/issues/#{@item.existing_issue.id}"}
              id={"triage-ticket-tracked-#{@item.id}"}
              class="font-mono text-blue-600 dark:text-blue-400 hover:underline"
            >
              {@item.existing_issue.identifier}
            </.link>
            <span class="whitespace-nowrap text-slate-500 dark:text-slate-400">
              {Issue.state_label(@item.existing_issue.state)}
            </span>
            <span class="min-w-0 truncate text-slate-500 dark:text-slate-400">· {@item.title}</span>
          </p>
          <label
            for={"triage-ticket-followup-#{@item.id}"}
            class="block text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400"
          >
            Follow-up comment on {@item.existing_issue.identifier}
          </label>
          <textarea
            id={"triage-ticket-followup-#{@item.id}"}
            name="item[followup_text]"
            rows="2"
            phx-debounce="400"
            readonly={@readonly}
            placeholder="Nothing to add, so no comment"
            class="w-full px-2.5 py-1.5 text-[12.5px] leading-relaxed break-words rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-400 resize-y"
          >{@item.followup_text}</textarea>
        </div>
        <div :if={@show_fields} class="px-4 pb-4 grid grid-cols-[minmax(0,1fr)_auto] gap-3">
          <textarea
            id={"triage-ticket-description-#{@item.id}"}
            name="item[issue_description]"
            rows="3"
            aria-label="Description"
            phx-debounce="400"
            readonly={@readonly}
            class="w-full px-2.5 py-1.5 text-[12.5px] leading-relaxed break-words rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 resize-y"
          >{@item.issue_description}</textarea>
          <div class="flex flex-col gap-2">
            <select
              id={"triage-ticket-priority-#{@item.id}"}
              name="item[issue_priority]"
              aria-label="Priority"
              disabled={@readonly}
              class="w-28 px-2.5 py-1 text-[12.5px] rounded-md border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              {Phoenix.HTML.Form.options_for_select(@priorities, @item.issue_priority || "")}
            </select>
            <select
              id={"triage-ticket-estimate-#{@item.id}"}
              name="item[issue_estimate]"
              aria-label="Estimate"
              disabled={@readonly}
              class="w-28 px-2.5 py-1 text-[12.5px] rounded-md border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              {Phoenix.HTML.Form.options_for_select(@estimates, @item.issue_estimate || "")}
            </select>
          </div>
        </div>
      </form>
    </article>
    """
  end

  attr :item_id, :string, required: true
  attr :issue, Issue, required: true

  # Triage only points to the issue page, so starting a task stays where Start at Plan is. A closed
  # issue has nothing to start there, so it shows its state instead.
  defp created(assigns) do
    finished = Issue.finished_state?(assigns.issue.state)

    assigns =
      assigns
      |> assign(:show_start, !assigns.issue.task and not finished)
      |> assign(:show_state, !assigns.issue.task and finished)

    ~H"""
    <span
      id={"triage-ticket-created-#{@item_id}"}
      class="inline-flex items-center gap-1.5 whitespace-nowrap text-[12px] text-slate-800 dark:text-slate-200"
    >
      <.icon name="pi-check-circle-fill" class="size-3.5 text-emerald-500" />Created
      <.link
        navigate={~p"/issues/#{@issue.id}"}
        id={"triage-ticket-issue-#{@item_id}"}
        class="font-mono text-blue-600 dark:text-blue-400 hover:underline rounded-sm focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        {@issue.identifier}
      </.link>
      <.link
        :if={@issue.task}
        navigate={~p"/tasks/#{@issue.task.id}"}
        id={"triage-ticket-task-#{@item_id}"}
        class="inline-flex items-center gap-1.5 h-6 px-2 rounded-full border border-slate-300 dark:border-slate-700 text-xs text-slate-600 dark:text-slate-300 hover:border-slate-500 focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        <.icon name="pi-git-branch" class="size-3.5" />{Task.stage_label(@issue.task)}
      </.link>
      <.link
        :if={@show_start}
        navigate={~p"/issues/#{@issue.id}"}
        id={"triage-ticket-start-#{@item_id}"}
        class="inline-flex items-center gap-1 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline rounded-sm focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        Start<.icon name="pi-arrow-right" class="size-3.5" />
      </.link>
      <span
        :if={@show_state}
        id={"triage-ticket-issue-state-#{@item_id}"}
        class="text-xs text-slate-500 dark:text-slate-400"
      >
        {Issue.state_label(@issue.state)}
      </span>
    </span>
    """
  end

  defp estimate_label(1), do: "1 point"
  defp estimate_label(points), do: "#{points} points"
end
