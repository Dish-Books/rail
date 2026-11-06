defmodule RailWeb.IssueLive do
  @moduledoc """
  One issue, laid out the way Linear lays it out: the title and description on
  the left with its comment threads beneath, its properties down the right. The
  status and assignee can be changed and comments posted here, and all three reach
  the tracker; everything else is edited there and arrives by sync or webhook.
  """
  use RailWeb, :live_view

  import RailWeb.Utils.HandleIssueEvent
  import RailWeb.Utils.IssueRelative
  import RailWeb.Utils.StartIssue

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
      # A task started from another tab or page replaces Start at with its link.
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
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
      |> assign(:pull_request, "")
      |> assign(:review_error, nil)

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
        current_scope={@current_scope}
        assignees={@assignees}
        assignee_query={@assignee_query}
        comment_nonce={@comment_nonce}
        checking_pull_request={@checking_pull_request}
        pull_request={@pull_request}
        review_error={@review_error}
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

  def handle_event(event, _params, socket) when event in ["start_task", "adopt_pull_request"] do
    {:noreply, start_issue(socket, socket.assigns.issue.id, &load_issue(&1, &1.assigns.issue.id))}
  end

  # Held here, so a reload of the issue while it is typed keeps it.
  def handle_event("draft_review", %{"pull_request" => reference}, socket) do
    {:noreply, assign(socket, :pull_request, reference)}
  end

  # A refusal stays under the field with what was typed, so it can be corrected rather than typed again.
  def handle_event("start_review", %{"pull_request" => reference}, socket) do
    %{current_scope: scope, issue: issue} = socket.assigns

    case Pipeline.start_task(scope, issue, :review, reference) do
      {:ok, task} ->
        {:noreply, push_navigate(socket, to: ~p"/tasks/#{task.id}")}

      {:error, reason} ->
        socket =
          socket
          |> assign(:pull_request, reference)
          |> assign(:review_error, review_error(reason, issue.project))
          |> load_issue(issue.id)

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

  # Any task could be this issue's new one while it has none; once it has one, only that task's changes show here.
  def handle_info({:pipeline_changed, task_id}, %{assigns: %{issue: %{task: task} = issue}} = socket)
      when is_nil(task) or task.id == task_id do
    {:noreply, load_issue(socket, issue.id)}
  end

  def handle_info({:pipeline_changed, _other_task_id}, socket), do: {:noreply, socket}

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
      task: [:rounds, runs: :role, parent_task: [children: :issue]],
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

  defp review_error(:not_a_pull_request, _project), do: "Give the pull request's number, such as #212, or its link."
  defp review_error({:other_repository, repo}, project), do: "That links to #{repo}, not #{project.github_repo}."
  defp review_error({:no_pull_request, repo, number}, _project), do: "#{repo} has no pull request ##{number}."

  defp review_error({:pull_request_merged, number}, _project),
    do: "##{number} is merged, so there is nothing left to review."

  defp review_error({:pull_request_closed, number}, _project),
    do: "##{number} is closed, so there is nothing left to review."

  defp review_error({:pull_request_from_fork, number}, _project),
    do: "##{number} comes from a fork, so Rail could not push fixes to it."

  defp review_error({:pull_request_into, number, base, default}, _project),
    do: "##{number} merges into #{base}, not #{default}."

  defp review_error({:pull_request_taken, number, identifier}, _project), do: "#{identifier} already works on ##{number}."
  defp review_error({:branch_failed, output}, _project), do: "Could not check out the pull request's branch: #{output}"
  # Reading the pull request and the token for its branch's fetch both ask GitHub, so these words fit either.
  defp review_error({:github_api_error, status, _body}, _project),
    do: "GitHub answered #{status}, so Rail could not take the pull request. Try again."

  defp review_error(exception, _project) when is_exception(exception),
    do: "Could not reach GitHub, so Rail could not take the pull request. Try again."

  defp review_error(reason, _project), do: "Could not start: #{inspect(reason)}"
end
