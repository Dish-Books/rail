defmodule RailWeb.IssueLive do
  @moduledoc """
  One issue, laid out the way Linear lays it out: the title and description on
  the left with its comment threads beneath, its properties down the right. The
  assignee can be changed and comments posted here, and both reach Linear;
  everything else is edited in Linear and arrives by sync or webhook.
  """
  use RailWeb, :live_view

  import RailWeb.Utils.HandleIssueEvent

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users

  @issue_events ["assign", "filter_assignees", "draft_comment", "comment"]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    socket =
      socket
      |> assign(:page_title, "Issue")
      |> assign(:current_section, :issues)
      |> assign(:issue, nil)
      |> assign(:assignees, [])
      |> assign(:assignee_query, "")
      |> assign(:comment_nonce, 0)

    {:ok, socket}
  end

  # The owner menu offers only people who can open the issue, so it waits for the issue's project.
  def handle_params(%{"id" => id}, _uri, socket) do
    socket = load_issue(socket, id)

    socket =
      if issue = socket.assigns.issue,
        do: assign(socket, :assignees, Users.list_assignable_users(project_id: issue.project_id, tracker: issue.tracker)),
        else: socket

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
        owner_editable={
          not match?(%{task: %Task{parent_task_id: parent_id}} when is_binary(parent_id), @issue)
        }
      />
    </Layouts.app>
    """
  end

  def handle_event("start_task", %{"stage" => stage}, socket) do
    {:ok, stage} = Task.cast_stage(stage)

    case Pipeline.start_task(socket.assigns.issue, stage) do
      {:ok, task} ->
        {:noreply, push_navigate(socket, to: ~p"/tasks/#{task.id}")}

      {:error, reason} ->
        socket = socket |> put_flash(:error, start_error(reason)) |> load_issue(socket.assigns.issue.id)
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

  # The tracker may have closed the issue, which takes away the offer to start it.
  def handle_info({:issue_changed, issue_id}, %{assigns: %{issue: %{id: issue_id}}} = socket) do
    {:noreply, load_issue(socket, issue_id)}
  end

  def handle_info({:issue_changed, _other_issue_id}, socket), do: {:noreply, socket}

  def handle_info({:issue_created, _issue_id}, socket), do: {:noreply, socket}

  defp load_issue(socket, id) do
    preload = [
      :project,
      :owner_user,
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

  defp start_error({:worktree_failed, reason}), do: "Could not create the worktree: #{reason}"
  defp start_error({:spawn_failed, reason, _run}), do: "Could not start the agent: #{inspect(reason)}"
  defp start_error(:dispatch_disabled), do: "Dispatch is switched off, so no agent was started."
  defp start_error(reason), do: "Could not start: #{inspect(reason)}"
end
