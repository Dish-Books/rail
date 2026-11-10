defmodule RailWeb.Components.IssueView do
  @moduledoc """
  One issue, laid out the way Linear lays it out: the title and description on
  the left with its comment threads beneath, its properties down the right.

  The issue page and the task page's first tab are the same view of the same
  thing, so both render this; the task page hides the section pointing at the
  task the reader is already on. The events it raises - `assign`,
  `filter_assignees`, `comment`, `draft_comment`, `start_task`, `adopt_pull_request`, and for a
  Rail-tracked issue `edit_issue` and `remove_relation` - belong to whichever LiveView renders it.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Workflows.Schemas.Workflow
  alias RailWeb.Components.DescriptionEditor
  alias RailWeb.Components.IssuePicker
  alias RailWeb.Components.StatusPicker

  @estimates [nil, 1, 2, 3, 5, 8, 13]

  attr :issue, :any, required: true
  attr :current_scope, :any, required: true
  attr :assignees, :list, required: true
  attr :assignee_query, :string, required: true
  attr :comment_nonce, :integer, required: true
  attr :show_task, :boolean, default: true
  # While GitHub is asked for a pull request the issue's work was opened as, which it would start at Review on.
  attr :checking_pull_request, :boolean, default: false
  # A child of a split is owned through its parent, so its owner is read here, not changed.
  attr :owner_editable, :boolean, default: true
  # The workflow that opened the issue, named under its title; only admins can follow it to Settings.
  attr :workflow, :any, default: nil
  attr :link_workflow, :boolean, default: false
  # What blocks the issue and what it blocks, as `Rail.Issues.get_blockers/1` reads them; nil until Linear answers.
  attr :blockers, :any, default: nil

  def issue_view(assigns) do
    %Issue{id: issue_id} = issue = assigns.issue
    {done, total} = Issue.calculate_sub_issue_count(issue)
    sub_issues = Enum.map(Issue.calculate_children(issue), &%{issue: &1, in_project: true})

    # Each row says which way its relation points, so its x removes that one.
    blocked_by =
      for entry <- (assigns.blockers && assigns.blockers.blocked_by) || [],
          do: Map.put(entry, :remove, %{blocker_id: entry.issue.id, blocked_id: issue_id})

    blocks =
      for entry <- (assigns.blockers && assigns.blockers.blocks) || [],
          do: Map.put(entry, :remove, %{blocker_id: issue_id, blocked_id: entry.issue.id})

    assigns =
      assigns
      |> assign(:editable, issue.tracker == :local)
      |> assign(:parent, Issue.calculate_parent(issue))
      |> assign(:blocked_by, blocked_by)
      |> assign(:open_blocker_count, length(Issue.calculate_open_blockers(blocked_by)))
      |> assign(:blocks, blocks)
      |> assign(:related_ids, [issue_id | Enum.map(blocked_by ++ blocks, & &1.issue.id)])
      |> assign(:sub_issues, sub_issues)
      |> assign(:parent_exclude_ids, [issue_id | Enum.map(sub_issues, & &1.issue.id)])
      |> assign(:links, if(is_list(issue.links), do: issue.links, else: []))
      |> assign(:sub_issue_count, "#{done}/#{total}")
      # A Rail-tracked issue's link is this page.
      |> assign(:show_tracker_link, assigns.issue.url not in [nil, ""] and assigns.issue.tracker != :local)

    ~H"""
    <div id="issue-page" data-qa="issue-page" class="relative max-w-5xl mx-auto space-y-6">
      <nav class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400">
        <.link
          navigate={~p"/issues"}
          id="issue-back-link"
          class="hover:text-slate-900 dark:hover:text-slate-100"
        >
          Issues
        </.link>
        <.icon name="pi-caret-right" class="h-3 w-3" />
        <.link
          :if={@parent}
          navigate={~p"/issues/#{@parent.identifier}"}
          id="issue-parent-link"
          title={@parent.title}
          class="font-mono hover:text-slate-900 dark:hover:text-slate-100"
        >
          {@parent.identifier}
        </.link>
        <.icon :if={@parent} name="pi-caret-right" class="h-3 w-3" />
        <span id="issue-identifier" class="font-mono">{@issue.identifier}</span>
      </nav>

      <div class="flex flex-col lg:flex-row gap-10">
        <article class="flex-1 min-w-0 space-y-6">
          <div class="space-y-2">
            <h1
              :if={!@editable}
              id="issue-title"
              data-qa="issue-title"
              class="text-2xl font-semibold tracking-tight text-slate-900 dark:text-slate-100"
            >
              {@issue.title}
            </h1>
            <%!-- LiveView leaves the heading alone; the saved title rides on data-saved, which the hook takes when it can. --%>
            <h1
              :if={@editable}
              id={"issue-title-#{@issue.id}"}
              data-qa="issue-title"
              phx-hook="IssueTitle"
              phx-update="ignore"
              contenteditable="true"
              role="textbox"
              aria-label="Title"
              data-saved={@issue.title}
              data-placeholder="Issue title"
              phx-no-format
              class="text-2xl font-semibold tracking-tight text-slate-900 dark:text-slate-100 break-words cursor-text focus:outline-none"
            >{@issue.title}</h1>
            <p
              :if={@workflow}
              id="issue-workflow-byline"
              class="flex items-center gap-2 text-sm text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-repeat" class="h-4 w-4" />
              <span>
                Opened by the <.link
                  :if={@link_workflow}
                  navigate={~p"/settings/workflows"}
                  id="issue-workflow-link"
                  title="Settings › Workflows"
                  class="font-medium text-slate-700 dark:text-slate-200 underline decoration-slate-400 dark:decoration-slate-600 underline-offset-2 hover:decoration-slate-300 focus-visible:outline-2 focus-visible:outline-indigo-500 rounded"
                  phx-no-format
                >{Workflow.name(@workflow)}</.link>
                <span :if={!@link_workflow} class="font-medium text-slate-700 dark:text-slate-200">
                  {Workflow.name(@workflow)}
                </span>
                workflow on {Calendar.strftime(@issue.inserted_at, "%b %-d, %H:%M")} UTC
              </span>
            </p>
          </div>

          <.live_component
            :if={@editable}
            module={DescriptionEditor}
            id={"issue-description-editor-#{@issue.id}"}
            issue={@issue}
            current_scope={@current_scope}
            overlay_id={"issue-drop-overlay-#{@issue.id}"}
          />

          <div :if={!@editable} id="issue-description" data-qa="issue-description">
            <.markdown
              :if={@issue.description not in [nil, ""]}
              content={@issue.description}
              assets_base={~p"/issues/#{@issue.id}/assets"}
              class="text-slate-700 dark:text-slate-300"
            />
            <p
              :if={@issue.description in [nil, ""]}
              class="text-sm text-slate-400 dark:text-slate-500"
            >
              No description
            </p>
          </div>

          <.issue_relation_list
            :if={@blocked_by != []}
            id="issue-blocked-by"
            title="Blocked by"
            count={to_string(@open_blocker_count)}
            entries={@blocked_by}
            blocked
            removable={@editable}
          />

          <.issue_relation_list
            :if={@blocks != []}
            id="issue-blocks"
            title="Blocks"
            count={to_string(length(@blocks))}
            entries={@blocks}
            removable={@editable}
          />

          <div
            :if={@editable}
            id="issue-relation-pickers"
            class="flex flex-wrap items-center gap-1 -mx-2"
          >
            <.live_component
              module={IssuePicker}
              id={"issue-blocked-by-picker-#{@issue.id}"}
              kind={:blocked_by}
              issue={@issue}
              exclude_ids={@related_ids}
              current_scope={@current_scope}
            />
            <.live_component
              module={IssuePicker}
              id={"issue-blocks-picker-#{@issue.id}"}
              kind={:blocks}
              issue={@issue}
              exclude_ids={@related_ids}
              current_scope={@current_scope}
            />
          </div>

          <.issue_relation_list
            :if={@sub_issues != []}
            id="issue-sub-issues"
            title="Sub-issues"
            count={@sub_issue_count}
            entries={@sub_issues}
          />

          <section
            id="issue-comments"
            data-qa="issue-comments"
            class="space-y-4 pt-6 border-t border-slate-200 dark:border-slate-800"
          >
            <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Comments</h2>

            <div
              :for={thread <- threads(@issue.comments)}
              id={"comment-#{thread.id}"}
              class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
            >
              <div class="p-4 space-y-5">
                <.comment comment={thread} assets_base={~p"/issues/#{@issue.id}/assets"} />
                <div :for={reply <- by_time(thread.replies)} id={"comment-#{reply.id}"}>
                  <.comment comment={reply} assets_base={~p"/issues/#{@issue.id}/assets"} />
                </div>
              </div>

              <.comment_form
                id={"comment-reply-form-#{thread.id}"}
                nonce={@comment_nonce}
                parent_id={thread.id}
                placeholder="Leave a reply..."
              />
            </div>

            <div class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900">
              <.comment_form
                id="issue-comment-form"
                nonce={@comment_nonce}
                placeholder="Leave a comment..."
              />
            </div>
          </section>
        </article>

        <aside id="issue-sidebar" class="lg:w-72 shrink-0 space-y-8 text-sm">
          <section :if={@show_task} class="space-y-3">
            <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Task</h2>

            <.link
              :if={@issue.task != nil}
              navigate={~p"/tasks/#{@issue.task.id}"}
              id="issue-task-link"
              data-qa="issue-task-link"
              class="flex items-center gap-2 text-slate-900 dark:text-slate-100 hover:underline"
            >
              <.icon name="pi-git-branch" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
              <span>{stage_label(@issue.task, Task.stage_run(@issue.task))}</span>
            </.link>

            <div
              :if={@issue.task == nil and not Issue.finished_state?(@issue.state)}
              id="issue-start"
              class="space-y-2"
            >
              <p class="text-xs text-slate-500 dark:text-slate-400">Start at</p>
              <p
                :if={@checking_pull_request}
                id="issue-start-checking"
                class="text-xs text-slate-400 dark:text-slate-500"
              >
                Looking for a pull request...
              </p>
              <div :if={not @checking_pull_request} class="flex gap-1.5">
                <button
                  :if={is_nil(@issue.pr_number)}
                  type="button"
                  id="issue-start-plan"
                  data-qa="issue-start-plan"
                  phx-click="start_task"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 cursor-pointer"
                >
                  <.icon name="pi-play" class="h-3.5 w-3.5" />
                  <span>{Task.stage_label(hd(Issue.calculate_stages(@issue)))}</span>
                </button>
                <button
                  :if={@issue.pr_number}
                  type="button"
                  id="issue-start-review"
                  data-qa="issue-start-review"
                  phx-click="adopt_pull_request"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 cursor-pointer"
                >
                  <.icon name="pi-git-pull-request" class="h-3.5 w-3.5" />
                  <span>{Task.stage_label(:review)}</span>
                </button>
              </div>
              <a
                :if={@issue.pr_number}
                href={@issue.pr_url}
                target="_blank"
                rel="noopener"
                id="issue-pull-request"
                data-qa="issue-pull-request"
                class="flex items-baseline gap-1.5 text-xs text-slate-500 dark:text-slate-400 hover:underline"
              >
                <span class="font-mono">#{@issue.pr_number}</span>
                <span class="truncate">{@issue.pr_title}</span>
              </a>
            </div>

            <p
              :if={@issue.task == nil and Issue.finished_state?(@issue.state)}
              class="text-slate-400 dark:text-slate-500"
            >
              None
            </p>
          </section>

          <section class="space-y-3">
            <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Properties</h2>

            <.live_component
              module={StatusPicker}
              id={"issue-status-picker-#{@issue.id}"}
              issue={@issue}
              current_scope={@current_scope}
              labeled
            />

            <div
              :if={!@editable}
              id="issue-priority"
              data-qa="issue-priority"
              class="flex items-center gap-2.5"
            >
              <.priority_icon priority={@issue.priority} />
              <span>{Issue.priority_label(@issue.priority)}</span>
            </div>

            <.property_menu
              :if={@editable}
              id="issue-priority"
              options={
                for priority <- Issue.priorities(), do: {priority, Issue.priority_label(priority)}
              }
              current={@issue.priority}
              field="priority"
            >
              <:trigger>
                <.priority_icon priority={@issue.priority} />
                <span>{Issue.priority_label(@issue.priority)}</span>
              </:trigger>
              <:option :let={priority}><.priority_icon priority={priority} /></:option>
            </.property_menu>

            <div
              :if={!@owner_editable}
              id="issue-owner"
              data-qa="issue-owner"
              class="flex items-center gap-2.5"
            >
              <.assignee user={@issue.owner_user} />
              <span :if={@issue.owner_user}>{user_name(@issue.owner_user)}</span>
              <span :if={!@issue.owner_user} class="text-slate-400 dark:text-slate-500">Unassigned</span>
            </div>

            <div
              :if={@owner_editable}
              class="relative"
              phx-click-away={JS.hide(to: "#issue-owner-menu")}
            >
              <button
                type="button"
                id="issue-owner"
                data-qa="issue-owner"
                phx-click={JS.toggle(to: "#issue-owner-menu") |> JS.focus(to: "#issue-owner-search")}
                class="-mx-2 flex items-center gap-2.5 px-2 py-1 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
              >
                <.assignee user={@issue.owner_user} />
                <span :if={@issue.owner_user}>{user_name(@issue.owner_user)}</span>
                <span :if={!@issue.owner_user} class="text-slate-400 dark:text-slate-500">
                  Unassigned
                </span>
              </button>

              <div
                id="issue-owner-menu"
                class="hidden absolute z-20 left-0 top-full mt-1 w-64 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-lg"
              >
                <form
                  id="issue-owner-search-form"
                  phx-change="filter_assignees"
                  onsubmit="return false"
                >
                  <input
                    type="text"
                    id="issue-owner-search"
                    name="q"
                    value={@assignee_query}
                    phx-debounce="100"
                    autocomplete="off"
                    placeholder="Assign to..."
                    class="w-full px-3 py-2.5 text-sm bg-transparent border-0 border-b border-slate-200 dark:border-slate-700 text-slate-900 dark:text-slate-100 placeholder-slate-400 focus:outline-none focus:ring-0"
                  />
                </form>

                <ul class="max-h-72 overflow-y-auto p-1">
                  <li>
                    <button
                      type="button"
                      id="issue-assign-none"
                      phx-click={
                        JS.push("assign", value: %{user_id: ""}) |> JS.hide(to: "#issue-owner-menu")
                      }
                      class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
                    >
                      <.assignee user={nil} />
                      <span class="flex-1 text-left">No assignee</span>
                      <.icon :if={!@issue.owner_user_id} name="pi-check" class="h-4 w-4" />
                    </button>
                  </li>
                  <li :for={user <- matching_assignees(@assignees, @assignee_query)}>
                    <button
                      type="button"
                      id={"issue-assign-#{user.id}"}
                      phx-click={
                        JS.push("assign", value: %{user_id: user.id})
                        |> JS.hide(to: "#issue-owner-menu")
                      }
                      class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
                    >
                      <.assignee user={user} />
                      <span class="flex-1 text-left truncate">{user_name(user)}</span>
                      <.icon :if={@issue.owner_user_id == user.id} name="pi-check" class="h-4 w-4" />
                    </button>
                  </li>
                </ul>
              </div>
            </div>

            <div
              :if={!@editable}
              id="issue-estimate"
              data-qa="issue-estimate"
              class="flex items-center gap-2.5"
            >
              <.icon name="pi-triangle" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
              <span :if={@issue.estimate}>{@issue.estimate} Points</span>
              <span :if={!@issue.estimate} class="text-slate-400 dark:text-slate-500">No points</span>
            </div>

            <.property_menu
              :if={@editable}
              id="issue-estimate"
              options={
                for estimate <- estimates(@issue.estimate), do: {estimate, estimate_label(estimate)}
              }
              current={@issue.estimate}
              field="estimate"
            >
              <:trigger>
                <.icon name="pi-triangle" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
                <span class={!@issue.estimate && "text-slate-400 dark:text-slate-500"}>
                  {estimate_label(@issue.estimate)}
                </span>
              </:trigger>
              <:option>
                <.icon name="pi-triangle" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
              </:option>
            </.property_menu>

            <.live_component
              :if={@editable}
              module={IssuePicker}
              id={"issue-parent-picker-#{@issue.id}"}
              kind={:parent}
              issue={@issue}
              parent={@parent}
              exclude_ids={@parent_exclude_ids}
              current_scope={@current_scope}
            />
          </section>

          <section class="space-y-3">
            <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Project</h2>
            <p id="issue-project">{@issue.project.name}</p>
          </section>

          <section :if={@show_tracker_link or @links != [] or @issue.branch_name} class="space-y-3">
            <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Links</h2>

            <a
              :for={link <- @links}
              href={link.url}
              target="_blank"
              rel="noopener noreferrer"
              id={"issue-link-#{link.id}"}
              title={link.url}
              class="flex items-center gap-2.5 text-slate-900 dark:text-slate-100 hover:underline rounded focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              <.icon name={link_icon(link.url)} class="h-4 w-4 text-slate-500 dark:text-slate-400" />
              <span class="flex-1 min-w-0 truncate">{link.title}</span>
              <.icon name="pi-arrow-square-out" class="h-4 w-4 text-slate-400 dark:text-slate-500" />
            </a>

            <a
              :if={@show_tracker_link}
              href={@issue.url}
              target="_blank"
              rel="noopener noreferrer"
              id="issue-tracker-link"
              data-qa="issue-tracker-link"
              class="flex items-center gap-2.5 text-slate-900 dark:text-slate-100 hover:underline"
            >
              <.icon name="pi-arrow-square-out" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
              <span>Open in {Issue.tracker_label(@issue.tracker)}</span>
            </a>

            <button
              :if={@issue.branch_name}
              type="button"
              id="issue-branch"
              phx-hook="CopyText"
              data-copy-text={@issue.branch_name}
              title="Copy branch name"
              class="group w-full flex items-center gap-2.5 text-left text-slate-900 dark:text-slate-100 cursor-pointer"
            >
              <.icon name="pi-git-branch" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
              <span class="flex-1 min-w-0 font-mono text-xs truncate group-hover:underline">
                {@issue.branch_name}
              </span>
              <.icon name="pi-copy" class="h-4 w-4 text-slate-400 group-data-[copied=true]:hidden" />
              <.icon
                name="pi-check"
                class="h-4 w-4 text-green-600 hidden group-data-[copied=true]:inline-block"
              />
            </button>
          </section>
        </aside>
      </div>

      <%!-- The description's hook shows this while files are dragged over the page; a drop anywhere goes into it. --%>
      <div
        :if={@editable}
        id={"issue-drop-overlay-#{@issue.id}"}
        class="hidden absolute -inset-3 z-30 rounded-xl border-2 border-dashed border-blue-500 bg-blue-500/10 justify-center pointer-events-none"
      >
        <div class="sticky top-[40vh] self-start mt-[40vh] flex items-center gap-2 h-fit px-4 py-2 rounded-full bg-white dark:bg-slate-900 border border-blue-500 text-sm font-medium text-slate-900 dark:text-slate-100 shadow-lg">
          <.icon name="pi-image" class="h-4 w-4 text-blue-500 dark:text-blue-400" />Drop to add to the description
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :options, :list, required: true
  attr :current, :any, required: true
  attr :field, :string, required: true
  slot :trigger, required: true
  slot :option, required: true

  # A Properties line that opens a menu of values, each applied as it is picked.
  defp property_menu(assigns) do
    ~H"""
    <div
      class="relative"
      phx-click-away={JS.hide(to: "##{@id}-menu")}
      phx-window-keydown={JS.hide(to: "##{@id}-menu")}
      phx-key="Escape"
    >
      <button
        type="button"
        id={@id}
        data-qa={@id}
        aria-haspopup="menu"
        phx-click={JS.toggle(to: "##{@id}-menu") |> JS.focus_first(to: "##{@id}-menu")}
        class="-mx-2 w-[calc(100%+1rem)] flex items-center gap-2.5 px-2 py-1 rounded-lg text-left hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        {render_slot(@trigger)}
      </button>

      <div
        id={"#{@id}-menu"}
        role="menu"
        class="hidden absolute z-20 left-0 top-full mt-1 w-48 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-lg"
      >
        <ul class="max-h-80 overflow-y-auto p-1">
          <li :for={{value, label} <- @options}>
            <button
              type="button"
              role="menuitem"
              id={"#{@id}-#{value || "none"}"}
              phx-click={
                JS.push("edit_issue", value: %{@field => value || ""})
                |> JS.hide(to: "##{@id}-menu")
                |> JS.focus(to: "##{@id}")
              }
              class={[
                "w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left text-sm hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500",
                value == @current && "bg-slate-100 dark:bg-slate-800"
              ]}
            >
              {render_slot(@option, value)}
              <span>{label}</span>
              <.icon :if={value == @current} name="pi-check" class="h-4 w-4 ml-auto shrink-0" />
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :comment, :map, required: true
  attr :assets_base, :string, required: true

  defp comment(assigns) do
    assigns = assign(assigns, :author, comment_author(assigns.comment))

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-center gap-2.5 text-sm">
        <.assignee user={@author} />
        <span class="font-medium text-slate-900 dark:text-slate-100">{user_name(@author)}</span>
        <span
          class="text-xs text-slate-500 dark:text-slate-400"
          title={DateTime.to_string(@comment.inserted_at)}
        >
          {time_ago(@comment.inserted_at)}
        </span>
      </div>
      <.markdown
        content={@comment.body}
        assets_base={@assets_base}
        class="pl-8.5 text-slate-700 dark:text-slate-300"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :nonce, :integer, required: true
  attr :parent_id, :string, default: nil
  attr :placeholder, :string, required: true

  # The textarea's id changes with each post, so a sent comment clears it.
  defp comment_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="draft_comment"
      phx-submit="comment"
      class="flex items-end gap-2 px-4 py-3 border-t first:border-t-0 border-slate-200 dark:border-slate-700"
    >
      <input :if={@parent_id} type="hidden" name="parent_id" value={@parent_id} />
      <textarea
        id={"#{@id}-body-#{@nonce}"}
        name="body"
        rows="1"
        placeholder={@placeholder}
        class="flex-1 min-h-9 resize-y bg-transparent border-0 p-1.5 text-sm text-slate-900 dark:text-slate-100 placeholder-slate-400 focus:outline-none focus:ring-0"
      ></textarea>
      <button
        type="submit"
        title="Send"
        class="flex items-center justify-center h-8 w-8 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300 hover:bg-blue-600 hover:text-white cursor-pointer"
      >
        <.icon name="pi-arrow-up" class="h-4 w-4" />
      </button>
    </form>
    """
  end

  defp matching_assignees(users, query) do
    case query |> String.trim() |> String.downcase() do
      "" -> users
      term -> Enum.filter(users, &(&1 |> user_name() |> String.downcase() |> String.contains?(term)))
    end
  end

  defp user_name(user), do: user.name || user.login

  # An estimate the menu does not offer is shown as it is, in its place.
  defp estimates(current) when is_integer(current) and current not in @estimates,
    do: [nil | Enum.sort([current | tl(@estimates)])]

  defp estimates(_offered), do: @estimates

  defp estimate_label(nil), do: "No points"
  defp estimate_label(1), do: "1 Point"
  defp estimate_label(estimate), do: "#{estimate} Points"

  defp link_icon(url) do
    if (URI.parse(url).host || "") =~ ~r/(^|\.)slack\.com$/, do: "pi-slack-logo", else: "pi-link-simple"
  end

  # Threads are the comments that answer nothing; their replies hang off them.
  defp threads(comments), do: comments |> Enum.filter(&is_nil(&1.parent_id)) |> by_time()

  defp by_time(comments), do: Enum.sort_by(comments, & &1.inserted_at, DateTime)

  # Someone who never joined Rail is shown as the tracker names them.
  defp comment_author(%{author_user: %{} = user}), do: user

  defp comment_author(comment) do
    name = comment.author_name || "Linear"
    %{name: name, login: name, avatar_url: comment.author_avatar_url}
  end

  defp time_ago(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
