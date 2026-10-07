defmodule RailWeb.Utils.HandleIssueEvent do
  @moduledoc """
  The events `RailWeb.Components.IssueView` raises for its owner menu and comments,
  for every LiveView that renders it. Each passes how it reloads the issue afterwards.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  # A page with no issue loaded, such as another tab of a task, has nothing to change.
  def handle_issue_event(_event, _params, %{assigns: %{issue: nil}} = socket, _reload), do: socket

  def handle_issue_event("filter_assignees", %{"q" => query}, socket, _reload) do
    assign(socket, :assignee_query, query)
  end

  # A child of a split has its parent's owner and no other.
  def handle_issue_event(
        "assign",
        _params,
        %{assigns: %{issue: %Issue{task: %Task{parent_task_id: parent_id}}}} = socket,
        _reload
      )
      when is_binary(parent_id), do: socket

  def handle_issue_event("assign", %{"user_id" => ""}, socket, reload), do: assign_owner(socket, nil, reload)

  # Only a user the menu offers: one the issue's tracker can assign who can open the issue.
  def handle_issue_event("assign", %{"user_id" => user_id}, socket, reload) do
    if Enum.any?(socket.assigns.assignees, &(&1.id == user_id)),
      do: assign_owner(socket, user_id, reload),
      else: socket
  end

  # A draft lives in its textarea until it is sent.
  def handle_issue_event("draft_comment", _params, socket, _reload), do: socket

  def handle_issue_event("comment", %{"body" => body} = params, socket, reload) do
    case String.trim(body) do
      "" -> socket
      body -> post_comment(socket, %{body: body, parent_id: params["parent_id"]}, reload)
    end
  end

  defp assign_owner(%{assigns: %{issue: issue}} = socket, owner_user_id, reload) do
    case Issues.update_issue(issue, %{owner_user_id: owner_user_id}) do
      {:ok, issue} ->
        {:ok, _children} = Pipeline.share_owner_with_children(issue)
        socket |> assign(:assignee_query, "") |> reload.()

      {:error, _changeset} ->
        put_flash(socket, :error, "Could not change the assignee")
    end
  end

  defp post_comment(%{assigns: %{issue: issue, current_scope: scope}} = socket, attrs, reload) do
    case Issues.comment(scope, issue, attrs) do
      {:ok, _comment} -> socket |> update(:comment_nonce, &(&1 + 1)) |> reload.()
      {:error, _reason} -> put_flash(socket, :error, "Could not post the comment")
    end
  end
end
