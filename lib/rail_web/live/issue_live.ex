defmodule RailWeb.IssueLive do
  @moduledoc """
  One issue, laid out the way Linear lays it out: the title and description on
  the left with its comment threads beneath, its properties down the right. The
  assignee can be changed and comments posted here, and both reach Linear;
  everything else is edited in Linear and arrives by sync or webhook.
  """
  use RailWeb, :live_view

  import RailWeb.Utils.HandleIssueEvent
  import RailWeb.Utils.IssueRelative

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users

  @issue_events ["assign", "filter_assignees", "draft_comment", "comment"]

  def mount(_params, _session, socket) do
    # Workflows too, since the byline names the workflow that opened the issue.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
      Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")
    end

    socket =
      socket
      |> assign(:page_title, "Issue")
      |> assign(:current_section, :issues)
      |> assign(:issue, nil)
      |> assign(:assignees, [])
      |> assign(:assignee_query, "")
      |> assign(:comment_nonce, 0)
      |> assign(:checking_pull_request, false)
      |> assign(:blockers, nil)

    {:ok, socket}
  end

  # The owner menu offers only people who can open the issue, so it waits for the issue's project.
  def handle_params(%{"id" => id}, _uri, socket) do
    socket = load_issue(socket, id)

    socket =
      if issue = socket.assigns.issue,
        do: assign(socket, :assignees, Users.list_assignable_users(project_id: issue.project_id, tracker: issue.tracker)),
        else: socket

    socket = socket |> link_pull_request() |> read_blockers()
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
      <.issue_view
        :if={@issue}
        issue={@issue}
        assignees={@assignees}
        assignee_query={@assignee_query}
        comment_nonce={@comment_nonce}
        checking_pull_request={@checking_pull_request}
        owner_editable={
          not match?(%{task: %Task{parent_task_id: parent_id}} when is_binary(parent_id), @issue)
        }
        workflow={@issue.workflow}
        link_workflow={Scope.admin?(@current_scope)}
        blockers={@blockers}
      />
    </Layouts.app>
    """
  end

  def handle_event("start_task", _params, socket) do
    case Pipeline.start_task(socket.assigns.issue) do
      {:ok, task} ->
        {:noreply, push_navigate(socket, to: ~p"/tasks/#{task.id}")}

      {:error, reason} ->
        socket = socket |> put_flash(:error, start_error(reason)) |> load_issue(socket.assigns.issue.id)
        {:noreply, socket}
    end
  end

  def handle_event("adopt_pull_request", _params, socket) do
    case Pipeline.adopt_pull_request(socket.assigns.current_scope, socket.assigns.issue) do
      {:ok, task} ->
        {:noreply, push_navigate(socket, to: ~p"/tasks/#{task.id}")}

      {:error, reason} ->
        socket = socket |> put_flash(:error, adopt_error(reason)) |> load_issue(socket.assigns.issue.id)
        {:noreply, socket}
    end
  end

  def handle_event(event, params, socket) when event in @issue_events do
    {:noreply, handle_issue_event(event, params, socket, &load_issue(&1, &1.assigns.issue.id))}
  end

  # A sync may have changed what the tracker says about this issue.
  def handle_info({:issues_synced, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_info({:issues_synced, _other_project_id}, socket), do: {:noreply, socket}

  def handle_info({:issue_comments_changed, issue_id}, %{assigns: %{issue: %{id: issue_id}}} = socket) do
    {:noreply, load_issue(socket, issue_id)}
  end

  def handle_info({:issue_comments_changed, _other_issue_id}, socket), do: {:noreply, socket}

  # The tracker may have closed the issue, which takes away the offer to start it, or changed its parent, a sub-issue
  # or a blocker. Linear sends nothing for a relation, so blockers are read again when this issue or one changes.
  def handle_info({event, changed_id}, %{assigns: %{issue: %Issue{} = issue, blockers: blockers}} = socket)
      when event in [:issue_changed, :issue_created] do
    socket = if issue_relative?(issue, blockers, changed_id), do: load_issue(socket, issue.id), else: socket
    blocker_ids = for %{issue: %Issue{id: id}} <- (blockers && blockers.blocked_by ++ blockers.blocks) || [], do: id

    socket = if changed_id == issue.id or changed_id in blocker_ids, do: read_blockers(socket), else: socket
    {:noreply, socket}
  end

  # A sync may have renamed the workflow that opened this issue.
  def handle_info({:workflows_changed, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_info({:workflows_changed, _other_project_id}, socket), do: {:noreply, socket}

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

  defp load_issue(socket, id) do
    preload = [
      :project,
      :owner_user,
      :workflow,
      :parent,
      :children,
      task: [runs: :role, parent_task: [children: :issue]],
      comments: [:author_user, replies: :author_user]
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
        {issue.id, Map.get(Issues.get_blockers([issue]), issue.external_id, %{blocked_by: [], blocks: []})}
      end)
    else
      socket
    end
  end

  defp read_blockers(socket), do: socket

  defp start_error({:worktree_failed, reason}), do: "Could not create the worktree: #{reason}"
  defp start_error({:spawn_failed, reason, _run}), do: "Could not start the agent: #{inspect(reason)}"
  defp start_error(:dispatch_disabled), do: "Dispatch is switched off, so no agent was started."
  defp start_error(reason), do: "Could not start: #{inspect(reason)}"

  defp adopt_error(:no_pull_request), do: "The pull request is no longer open."
  defp adopt_error(:pull_request_from_fork), do: "That pull request comes from a fork, which Rail cannot push fixes to."
  defp adopt_error({:pull_request_base, base}), do: "That pull request merges into #{base}, not the default branch."
  defp adopt_error(:pull_request_taken), do: "Another task already works on that pull request's branch."
  defp adopt_error(reason) when is_binary(reason), do: "Could not check out the pull request: #{reason}"
  defp adopt_error(reason), do: "Could not start: #{inspect(reason)}"
end
