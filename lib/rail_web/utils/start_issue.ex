defmodule RailWeb.Utils.StartIssue do
  @moduledoc """
  Finds, adopts or starts an issue's task off any page's process, and leaves what follows to the page. Only a pull
  request already linked is adopted, as asking GitHub here held every start up; the issue page links one as it opens.
  """
  alias Ecto.Changeset
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  # Read again rather than trusted from the page: the id comes from the browser, and a start from a stale page finds
  # the task another tab made.
  def start_issue(%Scope{} = scope, issue_id) do
    with {:ok, %User{github_id: github_id}} when is_binary(github_id) <- Users.get_user(id: scope.user.id),
         {:ok, %Issue{} = issue} <- Issues.get_issue(issue_id, preload: [:project, :task]),
         true <- Scope.can_access_project?(scope, issue.project_id) and not Issue.finished_state?(issue.state) do
      cond do
        match?(%Task{}, issue.task) ->
          {:ok, issue.task}

        # The task starts from the ticket the agent leaves, which may still change.
        Issue.chatting?(issue) ->
          {:error, "The agent is still answering on this issue. Start it once the agent finishes."}

        is_integer(issue.pr_number) ->
          scope |> Pipeline.adopt_pull_request(issue) |> explain(&adopt_error/1)

        true ->
          scope |> Pipeline.start_task(issue) |> explain(&start_error/1)
      end
    else
      {:ok, %User{}} -> {:error, "Connect GitHub in Connected accounts before you start an issue."}
      _gone_or_refused -> {:error, :not_found}
    end
  end

  defp explain({:ok, %Task{}} = started, _error), do: started
  defp explain({:error, reason}, error), do: {:error, error.(reason)}

  defp start_error(%Changeset{errors: [issue_id: _taken]}), do: someone_else()
  defp start_error(:task_exists), do: someone_else()
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

  # Another tab's start committed first: the create found its task, or the unique index refused the insert.
  defp someone_else, do: "Someone else just started this issue."
end
