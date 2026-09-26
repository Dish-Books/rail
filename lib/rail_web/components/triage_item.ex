defmodule RailWeb.Components.TriageItem do
  @moduledoc """
  One item of a triaged thread: its verdict and the evidence behind it, the
  assumptions a person can correct, and the issue and reply it proposes, which
  stay drafts until a person accepts them. A settled item folds to one line.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Triage.Schemas.Item

  attr :item, Item, required: true
  attr :form, :any, required: true, doc: "the item's draft changeset"
  attr :slack_linked, :boolean, required: true
  attr :current_user_id, :string, required: true
  attr :project_name, :string, required: true
  attr :corrected_by, :string, default: nil
  attr :error, :string, default: nil

  def triage_item(%{item: %Item{retriaging: true}} = assigns) do
    ~H"""
    <article
      id={"triage-item-#{@item.id}"}
      data-qa="triage-item"
      data-state="retriaging"
      class="flex items-center gap-2.5 px-4 py-2.5 rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 text-[12.5px]"
    >
      <span class="relative flex size-2">
        <span class="absolute inline-flex size-full rounded-full bg-blue-400 opacity-75 animate-ping"></span>
        <span class="relative size-2 rounded-full bg-blue-500"></span>
      </span>
      <span class="font-semibold text-slate-900 dark:text-slate-100">
        {@item.position} · {Item.kind_label(@item.kind)} · Triaging again with your correction
      </span>
    </article>
    """
  end

  def triage_item(assigns) do
    if Item.settled?(assigns.item), do: settled(assigns), else: open(assigns)
  end

  defp settled(assigns) do
    item = assigns.item

    assigns =
      assigns
      |> assign(:posted_line, posted_line(item))
      |> assign(:created_line, created_line(item, assigns.current_user_id))
      |> assign(:task, item.created_issue && item.created_issue.task)

    ~H"""
    <details
      id={"triage-item-#{@item.id}"}
      data-qa="triage-item"
      data-state="settled"
      class="group rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30 text-[12.5px]"
    >
      <summary class="flex items-center gap-2.5 px-4 py-2.5 cursor-pointer list-none">
        <.position position={@item.position} />
        <.triage_verdict kind={@item.kind} />
        <span class="font-semibold truncate text-slate-900 dark:text-slate-100">{@item.title}</span>
        <.triage_verdict kind={@item.kind} verdict={@item.verdict} />
        <span
          :if={@item.existing_issue}
          class="whitespace-nowrap text-slate-500 dark:text-slate-400"
        >
          in <span class="font-mono text-blue-600 dark:text-blue-400">{@item.existing_issue.identifier}</span>, {Issue.state_label(
            @item.existing_issue.state
          )}
        </span>
        <span class="ml-auto whitespace-nowrap inline-flex items-center gap-1 text-emerald-600 dark:text-emerald-400">
          <.icon name="pi-check-circle-fill" class="size-3.5" />{@posted_line}
        </span>
      </summary>
      <div class="px-4 pb-4 space-y-3">
        <p
          :if={@created_line}
          class="flex items-center gap-2 text-[13px] text-slate-800 dark:text-slate-200"
        >
          <.icon name="pi-check-circle-fill" class="size-4 text-emerald-500" />
          <span>{@created_line}</span>
          <.link
            :if={@task}
            navigate={~p"/tasks/#{@task.id}"}
            id={"triage-item-task-#{@item.id}"}
            class="ml-auto inline-flex items-center gap-1.5 h-6 px-2 rounded-full border border-slate-300 dark:border-slate-700 text-xs text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-git-branch" class="size-3.5" />{Task.stage_label(@task.stage)}
          </.link>
        </p>
        <div
          :if={@item.reply_posted_at}
          class="rounded-lg px-2.5 py-2 border-l-[3px] border-red-500 bg-slate-100 dark:bg-slate-800/40 text-[12.5px] leading-relaxed text-slate-800 dark:text-slate-200 whitespace-pre-line"
        >
          {@item.reply_text}
        </div>
        <p
          :if={@error || @item.error}
          id={"triage-item-error-#{@item.id}"}
          class="text-xs text-red-600 dark:text-red-400"
        >
          {@error || @item.error}
        </p>
      </div>
    </details>
    """
  end

  defp open(assigns) do
    item = assigns.item

    assigns =
      assigns
      |> assign(:show_issue_form, Item.issue_draft?(item) and is_nil(item.created_issue_id))
      |> assign(:show_reply_form, Item.reply_draft?(item) and is_nil(item.reply_posted_at))
      |> assign(:issue_edited, edited(item.issue_edited_by_id, item.issue_edited_by, assigns.current_user_id))
      |> assign(:reply_edited, edited(item.reply_edited_by_id, item.reply_edited_by, assigns.current_user_id))
      |> assign(:priorities, Enum.map(Issue.priorities(), &{Issue.priority_label(&1), &1}))
      |> assign(:error, assigns.error || item.error)

    ~H"""
    <article
      id={"triage-item-#{@item.id}"}
      data-qa="triage-item"
      data-state="open"
      class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
    >
      <header class="flex items-center gap-2.5 px-4 py-2.5 border-b border-slate-200 dark:border-slate-700">
        <.position position={@item.position} />
        <.triage_verdict kind={@item.kind} />
        <h3 class="text-sm font-semibold truncate text-slate-900 dark:text-slate-100">
          {@item.title}
        </h3>
        <.triage_verdict kind={@item.kind} verdict={@item.verdict} id={"triage-verdict-#{@item.id}"} />
        <span
          :if={@item.previous_verdict}
          id={"triage-redo-#{@item.id}"}
          class="ml-auto shrink-0 inline-flex items-center gap-1 text-[11px] text-slate-500 dark:text-slate-400"
        >
          <.icon name="pi-arrow-counter-clockwise" class="size-3.5 text-blue-500" />
          Redone after your correction. Was {Item.verdict_label(@item.previous_verdict)}.
        </span>
      </header>
      <div class="grid grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)] divide-x divide-slate-200 dark:divide-slate-700">
        <div class="p-4 space-y-3 min-w-0">
          <p
            :if={@item.summary}
            class="text-[13px] leading-relaxed text-slate-700 dark:text-slate-300"
          >
            {@item.summary}
          </p>
          <div
            :if={@item.kind == :bug and @item.evidence != []}
            class="space-y-1.5 font-mono text-[11px]"
          >
            <div
              :for={evidence <- @item.evidence}
              class="rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 px-2.5 py-1.5"
            >
              <p class="text-blue-600 dark:text-blue-400">{location(evidence)}</p>
              <p :if={evidence.excerpt} class="truncate text-slate-600 dark:text-slate-300">
                {evidence.excerpt}
              </p>
            </div>
          </div>
          <div
            :if={@item.kind == :feature_request and @item.evidence != []}
            class="space-y-1.5 text-[12.5px]"
          >
            <p :for={evidence <- @item.evidence} class="flex gap-2 text-slate-800 dark:text-slate-200">
              <.icon :if={evidence.holds} name="pi-check" class="size-3.5 mt-0.5 text-emerald-500" />
              <.icon :if={!evidence.holds} name="pi-x" class="size-3.5 mt-0.5 text-slate-400" />
              <span>
                {evidence.excerpt}
                <span class="font-mono text-[11px] text-blue-600 dark:text-blue-400">{location(
                  evidence
                )}</span>
              </span>
            </p>
          </div>
          <div :if={@item.assumptions != []}>
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              Assumptions
            </p>
            <ul class="mt-1.5 space-y-1.5 text-[12.5px]">
              <li :for={{assumption, index} <- Enum.with_index(@item.assumptions)} class="flex gap-2">
                <.icon
                  :if={assumption.corrected}
                  name="pi-user-check-fill"
                  class="size-3.5 mt-0.5 text-blue-500"
                />
                <.icon
                  :if={!assumption.corrected}
                  name="pi-question"
                  class="size-3.5 mt-0.5 text-slate-400"
                />
                <span class="flex-1 text-slate-700 dark:text-slate-300">
                  {assumption.text}
                  <span :if={assumption.corrected} class="text-slate-500 dark:text-slate-400">
                    Corrected by {@corrected_by || "a person"}.
                  </span>
                </span>
                <button
                  :if={!assumption.corrected}
                  type="button"
                  id={"correct-#{@item.id}-#{index}"}
                  phx-click={
                    JS.push("pick_correction",
                      value: %{item_id: @item.id, assumption: assumption.text}
                    )
                    |> JS.focus(to: "#correction-text")
                  }
                  class="text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline"
                >
                  Correct
                </button>
              </li>
            </ul>
          </div>
          <p :if={@item.issue_note} class="flex gap-2 text-[12px] text-slate-500 dark:text-slate-400">
            <.icon name="pi-magnifying-glass" class="size-3.5 mt-0.5" /><span>{@item.issue_note}</span>
          </p>
        </div>

        <div class="p-4 space-y-3 min-w-0">
          <p
            :if={@item.existing_issue}
            id={"triage-tracked-#{@item.id}"}
            class="flex items-center gap-2 text-[12.5px] text-slate-800 dark:text-slate-200"
          >
            <.icon name="pi-link" class="size-3.5 text-slate-400" />
            <span class="font-semibold">Already tracked, no new issue:</span>
            <span class="font-mono text-blue-600 dark:text-blue-400">{@item.existing_issue.identifier}</span>
            <span class="inline-flex items-center gap-1 text-slate-500 dark:text-slate-400">
              <.icon name="pi-circle" class="size-3" />{Issue.state_label(@item.existing_issue.state)}
            </span>
          </p>
          <p
            :if={@item.created_issue}
            class="flex items-center gap-2 text-[13px] text-slate-800 dark:text-slate-200"
          >
            <.icon name="pi-check-circle-fill" class="size-4 text-emerald-500" /> Created
            <span class="font-mono text-blue-600 dark:text-blue-400">{@item.created_issue.identifier}</span>
          </p>

          <.form
            :if={@show_issue_form}
            for={@form}
            id={"issue-form-#{@item.id}"}
            phx-change="update_draft"
            phx-submit="create_issue"
            class="space-y-1.5"
          >
            <input type="hidden" name="item_id" value={@item.id} />
            <div class="flex items-center gap-2">
              <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                New issue
              </p>
              <span class="px-1.5 rounded-full text-[10.5px] font-semibold border border-dashed border-slate-400 dark:border-slate-500 text-slate-500 dark:text-slate-400">
                Draft, not created
              </span>
              <span
                :if={@issue_edited}
                id={"issue-edited-#{@item.id}"}
                class="ml-auto text-[11px] text-blue-600 dark:text-blue-400 font-semibold"
              >
                {@issue_edited}
              </span>
            </div>
            <label class="sr-only" for={"issue-title-#{@item.id}"}>Issue title</label>
            <input
              type="text"
              id={"issue-title-#{@item.id}"}
              name="item[issue_title]"
              value={Ecto.Changeset.get_field(@form, :issue_title)}
              phx-debounce="500"
              class="w-full px-2.5 py-1.5 text-[13px] font-semibold rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100"
            />
            <textarea
              id={"issue-description-#{@item.id}"}
              name="item[issue_description]"
              rows="4"
              aria-label="Issue description"
              phx-debounce="500"
              class="w-full px-2.5 py-1.5 text-[12px] leading-relaxed rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 resize-none"
            >{Ecto.Changeset.get_field(@form, :issue_description)}</textarea>
            <div class="flex items-center gap-2">
              <select
                id={"issue-priority-#{@item.id}"}
                name="item[issue_priority]"
                aria-label="Priority"
                class="px-2 py-1 text-xs rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100"
              >
                {Phoenix.HTML.Form.options_for_select(
                  @priorities,
                  Ecto.Changeset.get_field(@form, :issue_priority) || :medium
                )}
              </select>
              <span class="text-[11px] text-slate-500 dark:text-slate-400">
                {@project_name} · starts Product · link posted in thread
              </span>
              <.button
                type="submit"
                variant="primary"
                size="sm"
                id={"create-issue-#{@item.id}"}
                disabled={!@slack_linked}
                class="ml-auto"
              >
                <.icon name="pi-check" class="size-3.5" />Create issue
              </.button>
            </div>
          </.form>

          <.form
            :if={@show_reply_form}
            for={@form}
            id={"reply-form-#{@item.id}"}
            phx-change="update_draft"
            phx-submit="post_reply"
            class={[
              "space-y-1.5",
              @show_issue_form && "pt-3 border-t border-slate-200 dark:border-slate-700"
            ]}
          >
            <input type="hidden" name="item_id" value={@item.id} />
            <div class="flex items-center gap-2">
              <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                Slack reply
              </p>
              <span class="px-1.5 rounded-full text-[10.5px] font-semibold border border-dashed border-slate-400 dark:border-slate-500 text-slate-500 dark:text-slate-400">
                Draft, not posted
              </span>
              <span
                :if={@reply_edited}
                id={"reply-edited-#{@item.id}"}
                class="ml-auto text-[11px] text-blue-600 dark:text-blue-400 font-semibold"
              >
                {@reply_edited}
              </span>
            </div>
            <textarea
              id={"reply-text-#{@item.id}"}
              name="item[reply_text]"
              rows="4"
              aria-label="Slack reply"
              phx-debounce="500"
              class="w-full px-2.5 py-1.5 text-[12.5px] leading-relaxed rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 resize-none"
            >{Ecto.Changeset.get_field(@form, :reply_text)}</textarea>
            <div class="flex items-center gap-2">
              <span class="text-[11px] text-slate-500 dark:text-slate-400">Posts in the thread as you.</span>
              <.button
                type="submit"
                variant="primary"
                size="sm"
                id={"post-reply-#{@item.id}"}
                disabled={!@slack_linked}
                class="ml-auto"
              >
                <.icon name="pi-paper-plane-tilt" class="size-3.5" />Post reply
              </.button>
            </div>
          </.form>

          <p
            :if={!@slack_linked and (@show_issue_form or @show_reply_form)}
            id={"connect-slack-#{@item.id}"}
            class="text-[11px] text-slate-500 dark:text-slate-400"
          >
            <.link
              navigate={~p"/settings/connected-accounts"}
              class="font-semibold text-blue-600 dark:text-blue-400 hover:underline"
            >
              Connect Slack to post as yourself
            </.link>
          </p>
          <p
            :if={@error}
            id={"triage-item-error-#{@item.id}"}
            class="text-xs text-red-600 dark:text-red-400"
          >
            {@error}
          </p>
        </div>
      </div>
    </article>
    """
  end

  attr :position, :integer, required: true

  defp position(assigns) do
    ~H"""
    <span class="flex items-center justify-center h-5 w-5 shrink-0 rounded-full bg-slate-200 dark:bg-slate-700 text-[11px] font-bold text-slate-900 dark:text-slate-100">
      {@position}
    </span>
    """
  end

  defp location(%{file: file, lines: lines}) when is_binary(lines), do: "#{file}:#{lines}"
  defp location(%{file: file}), do: file

  defp edited(nil, _user, _current_user_id), do: nil
  defp edited(user_id, _user, user_id), do: "Edited by you"
  defp edited(_user_id, user, _current_user_id), do: "Edited by #{user.name || user.login}"

  defp posted_line(%Item{reply_posted_at: %DateTime{} = at, reply_posted_by: user}) when is_map(user),
    do: "Reply posted by #{user.name || user.login} at #{Calendar.strftime(at, "%-I:%M %p")}"

  defp posted_line(%Item{}), do: "Done"

  defp created_line(%Item{created_issue: %Issue{identifier: identifier}, issue_edited_by_id: user_id}, user_id)
       when is_binary(user_id), do: "Created #{identifier} with your edits"

  defp created_line(%Item{created_issue: %Issue{identifier: identifier}}, _current_user_id), do: "Created #{identifier}"
  defp created_line(%Item{}, _current_user_id), do: nil
end
