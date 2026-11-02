defmodule RailWeb.Utils.StartIssue do
  @moduledoc """
  Starts an issue from any page: the one place that decides between opening the task it has, adopting its pull
  request and starting at its first stage. The page passes how it reloads afterwards.
  """
  use RailWeb, :verified_routes

  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Ecto.Changeset
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  # Read again rather than trusted from the page: the id comes from the browser, `start_task/1` takes no scope, and a
  # second start of a live task would spawn a second agent on it.
  def start_issue(socket, issue_id, reload) do
    scope = socket.assigns.current_scope

    with {:ok, %Issue{} = issue} <- Issues.get_issue(issue_id, preload: [:project, :task]),
         true <- Scope.can_access_project?(scope, issue.project_id) and not Issue.finished_state?(issue.state) do
      cond do
        match?(%Task{}, issue.task) ->
          push_navigate(socket, to: ~p"/tasks/#{issue.task.id}")

        pull_request?(scope, issue) ->
          scope |> Pipeline.adopt_pull_request(issue) |> finish(socket, reload, &adopt_error/1)

        true ->
          issue |> Pipeline.start_task() |> finish(socket, reload, &start_error/1)
      end
    else
      _gone_or_refused -> reload.(socket)
    end
  end

  # GitHub not answering is no reason to hold a start back, as the issue page offers Plan when its own check fails.
  defp pull_request?(%Scope{}, %Issue{pr_number: number}) when is_integer(number), do: true

  defp pull_request?(%Scope{} = scope, %Issue{} = issue) do
    match?({:ok, %{}}, Issues.link_pull_request(scope, issue))
  end

  defp finish({:ok, %Task{} = task}, socket, _reload, _error), do: push_navigate(socket, to: ~p"/tasks/#{task.id}")
  defp finish({:error, reason}, socket, reload, error), do: socket |> put_flash(:error, error.(reason)) |> reload.()

  defp start_error(%Changeset{errors: [issue_id: _taken]}), do: someone_else()
  defp start_error({:worktree_failed, reason}) when is_binary(reason), do: "Could not create the worktree: #{reason}"
  defp start_error({:worktree_failed, reason}), do: "Could not create the worktree: #{inspect(reason)}"
  defp start_error({:spawn_failed, reason, _run}), do: "Could not start the agent: #{inspect(reason)}"
  defp start_error(:dispatch_disabled), do: "Dispatch is switched off, so no agent was started."
  defp start_error(reason), do: "Could not start: #{inspect(reason)}"

  defp adopt_error(%Changeset{errors: [issue_id: _taken]}), do: someone_else()
  defp adopt_error(:no_pull_request), do: "The pull request is no longer open."
  defp adopt_error(:pull_request_from_fork), do: "That pull request comes from a fork, which Rail cannot push fixes to."
  defp adopt_error({:pull_request_base, base}), do: "That pull request merges into #{base}, not the default branch."
  defp adopt_error(:pull_request_taken), do: "Another task already works on that pull request's branch."
  defp adopt_error(reason) when is_binary(reason), do: "Could not check out the pull request: #{reason}"
  defp adopt_error(reason), do: "Could not start: #{inspect(reason)}"

  # The unique index on a task's issue refused the insert, since another tab's start committed first.
  defp someone_else, do: "Someone else just started this issue."
end
