defmodule RailWeb.IssueLive do
  @moduledoc """
  One issue, laid out the way Linear lays it out: the title and description on
  the left, its properties down the right. Only the assignee can be changed here,
  and that change is pushed to Linear; everything else is edited in Linear and
  arrives by sync or webhook.
  """
  use RailWeb, :live_view

  import RailWeb.Components.IssueIcons
  import RailWeb.CoreComponents, only: [icon: 1, markdown: 1]

  alias Phoenix.LiveView.JS
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Users
  alias RailWeb.Components.StageLabel

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    socket =
      socket
      |> assign(:page_title, "Issue")
      |> assign(:current_section, :issues)
      |> assign(:current_project_id, nil)
      |> assign(:issue, nil)
      |> assign(:assignees, Users.list_linear_users())
      |> assign(:assignee_query, "")

    {:ok, socket}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, load_issue(socket, id)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
      <div :if={@issue} id="issue-page" data-qa="issue-page" class="max-w-5xl mx-auto space-y-6">
        <nav class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400">
          <.link
            navigate={~p"/issues"}
            id="issue-back-link"
            class="hover:text-slate-900 dark:hover:text-slate-100"
          >
            Issues
          </.link>
          <.icon name="pi-caret-right" class="h-3 w-3" />
          <span id="issue-identifier" class="font-mono">{@issue.identifier}</span>
        </nav>

        <div class="flex flex-col lg:flex-row gap-10">
          <article class="flex-1 min-w-0 space-y-6">
            <h1
              id="issue-title"
              data-qa="issue-title"
              class="text-2xl font-semibold tracking-tight text-slate-900 dark:text-slate-100"
            >
              {@issue.title}
            </h1>

            <div id="issue-description" data-qa="issue-description">
              <.markdown
                :if={@issue.description not in [nil, ""]}
                content={@issue.description}
                class="text-slate-700 dark:text-slate-300"
              />
              <p
                :if={@issue.description in [nil, ""]}
                class="text-sm text-slate-400 dark:text-slate-500"
              >
                No description
              </p>
            </div>
          </article>

          <aside id="issue-sidebar" class="lg:w-72 shrink-0 space-y-8 text-sm">
            <section class="space-y-3">
              <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Task</h2>

              <.link
                :if={@issue.task != nil}
                navigate={~p"/tasks/#{@issue.task.id}"}
                id="issue-task-link"
                data-qa="issue-task-link"
                class="flex items-center gap-2 text-slate-900 dark:text-slate-100 hover:underline"
              >
                <.icon name="pi-git-branch" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
                <span>{StageLabel.stage_label(@issue.task, stage_run(@issue.task))}</span>
              </.link>

              <button
                :if={@issue.task == nil and not Issue.finished_state?(@issue.state)}
                type="button"
                id="issue-start-product-run"
                data-qa="issue-start-product-run"
                phx-click="start_product_run"
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 cursor-pointer"
              >
                <.icon name="pi-play" class="h-3.5 w-3.5" />
                <span>Start</span>
              </button>

              <p
                :if={@issue.task == nil and Issue.finished_state?(@issue.state)}
                class="text-slate-400 dark:text-slate-500"
              >
                None
              </p>
            </section>

            <section class="space-y-3">
              <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Properties</h2>

              <div id="issue-status" data-qa="issue-status" class="flex items-center gap-2.5">
                <.status_icon state={@issue.state} />
                <span>{@issue.state_name || Issue.state_label(@issue.state)}</span>
              </div>

              <div id="issue-priority" data-qa="issue-priority" class="flex items-center gap-2.5">
                <.priority_icon priority={@issue.priority} />
                <span>{Issue.priority_label(@issue.priority)}</span>
              </div>

              <div class="relative" phx-click-away={JS.hide(to: "#issue-owner-menu")}>
                <button
                  type="button"
                  id="issue-owner"
                  data-qa="issue-owner"
                  phx-click={
                    JS.toggle(to: "#issue-owner-menu") |> JS.focus(to: "#issue-owner-search")
                  }
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

              <div id="issue-estimate" data-qa="issue-estimate" class="flex items-center gap-2.5">
                <.icon name="pi-triangle" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
                <span :if={@issue.estimate}>{@issue.estimate} Points</span>
                <span :if={!@issue.estimate} class="text-slate-400 dark:text-slate-500">No points</span>
              </div>
            </section>

            <section class="space-y-3">
              <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Project</h2>
              <p id="issue-project">{@issue.project.name}</p>
            </section>

            <section :if={@issue.url not in [nil, ""] or @issue.branch_name} class="space-y-3">
              <h2 class="text-xs font-medium text-slate-500 dark:text-slate-400">Links</h2>

              <a
                :if={@issue.url not in [nil, ""]}
                href={@issue.url}
                target="_blank"
                rel="noopener noreferrer"
                id="issue-linear-link"
                data-qa="issue-linear-link"
                class="flex items-center gap-2.5 text-slate-900 dark:text-slate-100 hover:underline"
              >
                <.icon name="pi-arrow-square-out" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
                <span>Open in Linear</span>
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
      </div>
    </Layouts.app>
    """
  end

  def handle_event("start_product_run", _params, socket) do
    with {:ok, task} <- Pipeline.create_task(socket.assigns.issue, :product) do
      Pipeline.start_product_run(task)
    end

    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_event("filter_assignees", %{"q" => query}, socket) do
    {:noreply, assign(socket, :assignee_query, query)}
  end

  def handle_event("assign", %{"user_id" => ""}, socket) do
    {:noreply, assign_owner(socket, nil)}
  end

  # Only a user with a linked Linear account can be assigned, since Linear has to
  # be told who they are.
  def handle_event("assign", %{"user_id" => user_id}, socket) do
    if Enum.any?(socket.assigns.assignees, &(&1.id == user_id)) do
      {:noreply, assign_owner(socket, user_id)}
    else
      {:noreply, socket}
    end
  end

  # A sync may have changed what Linear says about this issue.
  def handle_info({:issues_synced, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_info({:issues_synced, _other_project_id}, socket), do: {:noreply, socket}

  defp assign_owner(%{assigns: %{issue: issue}} = socket, owner_user_id) do
    case Issues.update_issue(issue, %{owner_user_id: owner_user_id}) do
      {:ok, _issue} -> socket |> assign(:assignee_query, "") |> load_issue(issue.id)
      {:error, _changeset} -> put_flash(socket, :error, "Could not change the assignee")
    end
  end

  defp load_issue(socket, id) do
    case Issues.get_issue(id, preload: [:project, :owner_user, task: [runs: :role]]) do
      {:ok, issue} ->
        socket
        |> assign(:issue, issue)
        |> assign(:page_title, "#{issue.identifier} #{issue.title}")
        |> assign(:current_project_id, issue.project_id)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Issue not found")
        |> push_navigate(to: ~p"/issues")
    end
  end

  defp matching_assignees(users, query) do
    case query |> String.trim() |> String.downcase() do
      "" -> users
      term -> Enum.filter(users, &(&1 |> user_name() |> String.downcase() |> String.contains?(term)))
    end
  end

  defp user_name(user), do: user.name || user.login

  # Where the task got to is what the run for the stage it sits at says.
  defp stage_run(%{runs: runs, stage: stage}) do
    Enum.find(runs, &(&1.role != nil and &1.role.stage == stage))
  end
end
