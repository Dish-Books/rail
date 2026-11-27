defmodule RailWeb.IssueLive do
  @moduledoc """
  One issue: the title and description on
  the left with its comment threads beneath, its properties down the right, and its agent chat beside it. The
  issue is edited here in full, its cycle and initiative included.
  """
  use RailWeb, :live_view

  import RailWeb.Utils.HandleIssueEvent
  import RailWeb.Utils.IssueRelative
  import RailWeb.Utils.StartIssue

  alias Rail.Initiatives
  alias Rail.Issues
  alias Rail.Issues.Schemas.ChatMessage
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  on_mount {RailWeb.UserAuth, {:require_tab, :issues}}

  @issue_events [
    "assign",
    "filter_assignees",
    "set_cycle",
    "set_initiative",
    "draft_comment",
    "comment",
    "edit_issue",
    "remove_relation"
  ]

  def mount(_params, _session, socket) do
    # Workflows too, since the byline names the workflow that opened the issue, and Rail's cycles, which the nightly
    # run moves issues between without a word on "issues". "pipeline" carries the Task section's stage and run,
    # "initiatives" the Initiative row's names, "users" whether the reader has GitHub connected, and "issue_chats" the
    # agent chat's lines and whether it is running.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
      Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")
      Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
      Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
      Phoenix.PubSub.subscribe(Rail.PubSub, "users")
      Phoenix.PubSub.subscribe(Rail.PubSub, "issue_chats")
    end

    %Scope{user: %User{github_id: github_id}} = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Issue")
      |> assign(:current_section, :issues)
      |> assign(:issue, nil)
      |> assign(:assignees, [])
      |> assign(:assignee_query, "")
      |> assign(:comment_nonce, %{})
      |> assign(:checking_pull_request, false)
      |> assign(:blockers, nil)
      |> assign(:cycles, nil)
      |> assign(:initiatives, nil)
      |> assign(:github_connected, is_binary(github_id))
      |> assign(:chat_form, Ecto.Changeset.change(%ChatMessage{}))

    {:ok, socket}
  end

  # The owner menu offers only people who can open the issue, so it waits for the issue's project.
  def handle_params(%{"id" => id}, _uri, socket) do
    socket = load_issue(socket, id)

    socket =
      if issue = socket.assigns.issue,
        do: assign(socket, :assignees, Users.list_assignable_users(project_id: issue.project_id)),
        else: socket

    socket = socket |> link_pull_request() |> read_blockers() |> read_cycles() |> read_initiatives()
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
      <div id="issue-layout" class="-m-6 h-[calc(100%+3rem)] flex min-h-0">
        <div id="issue-column" class="flex-1 min-w-0 overflow-y-auto p-6">
          <p
            :if={@issue && !@github_connected}
            id="issue-github-required"
            data-qa="issue-github-required"
            class="max-w-5xl mx-auto mb-6 flex items-start gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-4 py-3 text-sm text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-github-logo" class="size-4 mt-0.5 shrink-0 text-slate-400" />
            <span>
              Connect GitHub in
              <.link navigate={~p"/settings/connected-accounts"} class="underline">Connected accounts</.link>
              to change, comment on or start this issue.
            </span>
          </p>
          <.issue_view
            :if={@issue}
            issue={@issue}
            current_scope={@current_scope}
            assignees={@assignees}
            assignee_query={@assignee_query}
            comment_nonce={@comment_nonce}
            checking_pull_request={@checking_pull_request}
            owner_editable={
              not match?(%{task: %Task{parent_task_id: parent_id}} when is_binary(parent_id), @issue)
            }
            workflow={@issue.workflow}
            blockers={@blockers}
            cycles={@cycles}
            initiatives={@initiatives}
            read_only={!@github_connected}
          />
        </div>
        <.agent_chat
          :if={@issue}
          id="issue-chat"
          key={@issue.id}
          lines={@issue.chat_messages}
          running={Issue.chatting?(@issue)}
          error={if(@issue.task, do: nil, else: @issue.chat_error)}
          form={@chat_form}
          empty={chat_empty(@issue, @github_connected)}
          placeholder="Ask the agent about this issue"
          gone_author="A teammate"
          class="w-[400px] max-2xl:w-[320px] shrink-0 border-l border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
        >
          <:composer :if={@issue.task}>
            <p
              id="issue-chat-closed"
              class="flex items-center gap-2 text-[13px] text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-lock-simple" class="size-4 shrink-0" />
              <span class="min-w-0">
                The task has started, so this chat is closed.
                <.link
                  navigate={~p"/tasks/#{@issue.task.id}"}
                  id="issue-chat-task-link"
                  class="font-medium text-slate-700 dark:text-slate-200 underline decoration-slate-500 underline-offset-2 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
                >
                  Open the task
                </.link>
              </span>
            </p>
          </:composer>
          <:composer :if={!@issue.task and !@github_connected}>
            <p
              id="issue-chat-github"
              class="flex items-center gap-2 text-[13px] text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-github-logo" class="size-4 shrink-0" />
              <span class="min-w-0">
                Connect GitHub in
                <.link navigate={~p"/settings/connected-accounts"} class="underline">Connected accounts</.link>
                to message the agent.
              </span>
            </p>
          </:composer>
        </.agent_chat>
      </div>
    </Layouts.app>
    """
  end

  # Someone without GitHub reads the issue but changes nothing on it, whatever a stale page or a crafted event sends.
  def handle_event(_event, _params, %{assigns: %{github_connected: false}} = socket) do
    {:noreply, put_flash(socket, :error, "Connect GitHub in Connected accounts to work on this issue.")}
  end

  # The page stays put either way: reloaded, its Task section shows the task in place of Start.
  def handle_event(event, _params, socket) when event in ["start_task", "adopt_pull_request"] do
    %Issue{id: issue_id} = socket.assigns.issue

    socket =
      case start_issue(socket.assigns.current_scope, issue_id) do
        {:ok, %Task{}} -> load_issue(socket, issue_id)
        {:error, :not_found} -> load_issue(socket, issue_id)
        {:error, message} when is_binary(message) -> socket |> put_flash(:error, message) |> load_issue(issue_id)
      end

    {:noreply, socket}
  end

  # What is typed in the chat stays through the reloads broadcasts bring.
  def handle_event("chat_change", %{"chat_message" => attrs}, socket),
    do: {:noreply, assign(socket, :chat_form, Ecto.Changeset.change(%ChatMessage{}, text: attrs["text"]))}

  # A reconnect while the agent works recovers the disabled chat box with no text: nothing changed.
  def handle_event("chat_change", _params, socket), do: {:noreply, socket}

  # A refusal means the page is behind: a task started or a pass began in another tab, which the reload shows.
  def handle_event("chat", %{"chat_message" => attrs}, socket) do
    %Issue{id: issue_id} = issue = socket.assigns.issue

    socket =
      case Issues.send_issue_chat(socket.assigns.current_scope, issue, attrs) do
        {:ok, %ChatMessage{}} ->
          socket |> assign(:chat_form, Ecto.Changeset.change(%ChatMessage{})) |> load_issue(issue_id)

        {:error, %Ecto.Changeset{} = changeset} ->
          assign(socket, :chat_form, changeset)

        {:error, reason} when reason in [:task_started, :agent_running, :not_found] ->
          load_issue(socket, issue_id)
      end

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @issue_events do
    {:noreply, handle_issue_event(event, params, socket, &load_issue(&1, &1.assigns.issue.id))}
  end

  # Connecting or disconnecting GitHub with the page open turns its controls on or off in place.
  def handle_info({:users_changed, id}, %{assigns: %{current_scope: %Scope{user: %User{id: id}}}} = socket) do
    github_connected = match?({:ok, %User{github_id: github_id}} when is_binary(github_id), Users.get_user(id: id))
    {:noreply, assign(socket, :github_connected, github_connected)}
  end

  def handle_info({:users_changed, _someone_else}, socket), do: {:noreply, socket}

  def handle_info({:issue_comments_changed, issue_id}, %{assigns: %{issue: %{id: issue_id}}} = socket) do
    {:noreply, load_issue(socket, issue_id)}
  end

  def handle_info({:issue_comments_changed, _other_issue_id}, socket), do: {:noreply, socket}

  def handle_info({:issue_chat_changed, issue_id}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket),
    do: {:noreply, load_issue(socket, issue_id)}

  def handle_info({:issue_chat_changed, _other_issue_id}, socket), do: {:noreply, socket}

  # A run admitted, finished or waiting on a person is said only on "pipeline", and the Task section shows it.
  def handle_info({:pipeline_changed, task_id}, %{assigns: %{issue: %Issue{task: %Task{id: task_id}}}} = socket) do
    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_info({:pipeline_changed, _other_task_id}, socket), do: {:noreply, socket}

  # The tracker may have closed the issue, which takes away the offer to start it, or changed its parent, a sub-issue
  # or a blocker. Blockers are read again when this issue or one of them changes, and the initiatives on any change,
  # since a ticket moving can move this one's initiative's percent.
  def handle_info({event, changed_id}, %{assigns: %{issue: %Issue{} = issue, blockers: blockers}} = socket)
      when event in [:issue_changed, :issue_created] do
    socket = if issue_relative?(issue, blockers, changed_id), do: load_issue(socket, issue.id), else: socket
    blocker_ids = for %{issue: %Issue{id: id}} <- (blockers && blockers.blocked_by ++ blockers.blocks) || [], do: id

    socket = if changed_id == issue.id or changed_id in blocker_ids, do: read_blockers(socket), else: socket
    socket = read_initiatives(socket)
    {:noreply, socket}
  end

  def handle_info({:issue_relations_changed, ids}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket) do
    socket = if issue_id in ids, do: read_blockers(socket), else: socket
    {:noreply, socket}
  end

  # A sync may have renamed the workflow that opened this issue.
  def handle_info({:workflows_changed, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_info({:workflows_changed, _other_project_id}, socket), do: {:noreply, socket}

  def handle_info({:cycles_changed, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    socket = socket |> load_issue(socket.assigns.issue.id) |> read_cycles()
    {:noreply, socket}
  end

  def handle_info({:cycles_changed, _other_project_id}, socket), do: {:noreply, socket}

  # Its initiative may have been renamed, or deleted, which leaves the issue with none.
  def handle_info({:initiatives_changed, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    socket = socket |> load_issue(socket.assigns.issue.id) |> read_initiatives()
    {:noreply, socket}
  end

  def handle_info({:initiatives_changed, _other_project_id}, socket), do: {:noreply, socket}

  # Looking up GitHub is not something the page waits on: it offers Plan once GitHub has nothing, or cannot say.
  def handle_async(:link_pull_request, {:ok, {:ok, _pull_request}}, socket) do
    socket = socket |> assign(:checking_pull_request, false) |> load_issue(socket.assigns.issue.id)
    {:noreply, socket}
  end

  def handle_async(:link_pull_request, _failed, socket) do
    {:noreply, assign(socket, :checking_pull_request, false)}
  end

  # An answer read for an issue the page no longer shows is dropped.
  def handle_async(:blockers, {:ok, {issue_id, blockers}}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket) do
    {:noreply, assign(socket, :blockers, blockers)}
  end

  def handle_async(:blockers, _stale_or_failed, socket), do: {:noreply, socket}

  # The chat invites a question only while its box is open.
  defp chat_empty(%Issue{task: %Task{}}, _github_connected),
    do: "Nobody asked the agent about this issue before its task started."

  defp chat_empty(%Issue{}, false), do: "Nobody has asked the agent about this issue yet."

  defp chat_empty(%Issue{}, true),
    do:
      "Ask whether this issue still applies, or to sharpen it before you start. The agent reads the ticket, its comments, the code and the project's other tickets."

  defp load_issue(socket, id) do
    preload = [
      :project,
      :owner_user,
      :workflow,
      :parent,
      :children,
      :links,
      task: [:rounds, runs: :role, parent_task: [children: :issue]],
      comments: [:author_user, replies: :author_user],
      chat_messages: :user
    ]

    # An issue in a project the user cannot access is one that does not exist, as far as they can tell.
    with {:ok, issue} <- Issues.get_issue(id, preload: preload),
         true <- Scope.can_access_project?(socket.assigns.current_scope, issue.project_id) do
      socket
      |> assign(:issue, issue)
      |> assign(:page_title, "#{issue.identifier} #{issue.title}")
    else
      _not_found ->
        socket
        |> put_flash(:error, "Issue not found")
        |> push_navigate(to: ~p"/issues")
    end
  end

  # Work begun outside Rail is started at Review on its pull request, so an issue that could be started and has
  # none linked yet is checked once; the link is kept on the issue from then on.
  defp link_pull_request(%{assigns: %{issue: %Issue{task: nil, pr_number: nil} = issue}} = socket) do
    scope = socket.assigns.current_scope

    cond do
      Issue.finished_state?(issue.state) ->
        socket

      # Checking from the first render, so Plan never shows only to give way to Review.
      not connected?(socket) ->
        assign(socket, :checking_pull_request, true)

      true ->
        socket
        |> assign(:checking_pull_request, true)
        |> start_async(:link_pull_request, fn -> Issues.link_pull_request(scope, issue) end)
    end
  end

  defp link_pull_request(socket), do: socket

  # Read once connected, not in `load_issue/2`, which runs on every comment and sync.
  defp read_blockers(%{assigns: %{issue: %Issue{} = issue}} = socket) do
    if connected?(socket) do
      start_async(socket, :blockers, fn ->
        {issue.id, Map.get(Issues.get_blockers([issue]), issue.id, %{blocked_by: [], blocks: []})}
      end)
    else
      socket
    end
  end

  defp read_blockers(socket), do: socket

  defp read_cycles(%{assigns: %{issue: %Issue{project: project}}} = socket) do
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    assign(socket, :cycles, cycles)
  end

  defp read_cycles(socket), do: socket

  defp read_initiatives(%{assigns: %{issue: %Issue{project_id: project_id}}} = socket),
    do: assign(socket, :initiatives, Initiatives.list_initiatives(socket.assigns.current_scope, project_id: project_id))

  defp read_initiatives(socket), do: socket
end
