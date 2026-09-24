defmodule RailWeb.IssueLive do
  @moduledoc """
  One issue, laid out the way Linear lays it out: the title and description on
  the left with its comment threads beneath, its properties down the right. The
  assignee can be changed and comments posted here, and both reach Linear;
  everything else is edited in Linear and arrives by sync or webhook.
  """
  use RailWeb, :live_view

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users

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
      |> assign(:comment_nonce, 0)

    {:ok, socket}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, load_issue(socket, id)}
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

  # A draft lives in its textarea until it is sent.
  def handle_event("draft_comment", _params, socket), do: {:noreply, socket}

  def handle_event("comment", %{"body" => body} = params, socket) do
    case String.trim(body) do
      "" -> {:noreply, socket}
      body -> {:noreply, post_comment(socket, %{body: body, parent_id: params["parent_id"]})}
    end
  end

  # A sync may have changed what Linear says about this issue.
  def handle_info({:issues_synced, project_id}, %{assigns: %{issue: %{project_id: project_id}}} = socket) do
    {:noreply, load_issue(socket, socket.assigns.issue.id)}
  end

  def handle_info({:issues_synced, _other_project_id}, socket), do: {:noreply, socket}

  def handle_info({:issue_comments_changed, issue_id}, %{assigns: %{issue: %{id: issue_id}}} = socket) do
    {:noreply, load_issue(socket, issue_id)}
  end

  def handle_info({:issue_comments_changed, _other_issue_id}, socket), do: {:noreply, socket}

  def handle_info({:issue_created, _issue_id}, socket), do: {:noreply, socket}

  defp assign_owner(%{assigns: %{issue: issue}} = socket, owner_user_id) do
    case Issues.update_issue(issue, %{owner_user_id: owner_user_id}) do
      {:ok, _issue} -> socket |> assign(:assignee_query, "") |> load_issue(issue.id)
      {:error, _changeset} -> put_flash(socket, :error, "Could not change the assignee")
    end
  end

  defp post_comment(%{assigns: %{issue: issue, current_scope: scope}} = socket, attrs) do
    case Issues.comment(scope, issue, attrs) do
      {:ok, _comment} -> socket |> update(:comment_nonce, &(&1 + 1)) |> load_issue(issue.id)
      {:error, _reason} -> put_flash(socket, :error, "Could not post the comment")
    end
  end

  defp load_issue(socket, id) do
    preload = [:project, :owner_user, task: [runs: :role], comments: [:author_user, replies: :author_user]]

    case Issues.get_issue(id, preload: preload) do
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

  defp start_error({:worktree_failed, reason}), do: "Could not create the worktree: #{reason}"
  defp start_error({:spawn_failed, reason, _run}), do: "Could not start the agent: #{inspect(reason)}"
  defp start_error(:dispatch_disabled), do: "Dispatch is switched off, so no agent was started."
  defp start_error(reason), do: "Could not start: #{inspect(reason)}"
end
