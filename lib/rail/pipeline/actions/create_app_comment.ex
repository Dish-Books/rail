defmodule Rail.Pipeline.Actions.CreateAppComment do
  @moduledoc """
  Saves a comment on one element of the task's app, as a person used it inside Rail, unsent, for the person writing
  it. It goes to the Review lead with the screen comments, so it can be written where they can: from Review on, until
  the task is cleaned up.
  """

  import Rail.Pipeline.Utils.BroadcastScreenComments

  alias Rail.Git
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `body` on `element`, what `Rail.Tools.inspect_browser_element/5` said of the element the person picked, as the
  scope user's comment on `task`, against the commit the worktree is on.

  Returns `{:ok, comment}`, `{:error, changeset}`, or `{:error, reason}` when the task is cleaned up or has not reached
  Review.
  """
  def create_app_comment(%Scope{user: %{id: user_id}}, %Task{id: task_id}, %{selector: _selector} = element, body) do
    # Read again, so a page drawn before the task moved on cannot write after it.
    with %Task{cleaned_up_at: nil, stage: stage} = task when stage in [:review, :finalize, :merged] <-
           Repo.get!(Task, task_id),
         {:ok, comment} <- insert(task, user_id, element, body) do
      broadcast_screen_comments(task_id, user_id)
      {:ok, comment}
    else
      %Task{cleaned_up_at: %DateTime{}} -> {:error, :cleaned_up}
      %Task{stage: stage} -> {:error, {:invalid_stage, stage}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert(%Task{} = task, user_id, element, body) do
    commit = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]

    %ScreenComment{
      task_id: task.id,
      user_id: user_id,
      label: element |> Map.get(:url, "/") |> path(),
      commit: commit,
      picture_path: element[:picture]
    }
    |> ScreenComment.app_changeset(%{
      body: body,
      selector: element.selector,
      element_text: element[:text],
      element_tag: element[:tag]
    })
    |> Repo.insert()
  end

  # The page as a person would name it: its path and query, not the port the app happened to run on.
  defp path(url) do
    case URI.parse(url) do
      %URI{path: path, query: nil} -> path || "/"
      %URI{path: path, query: query} -> "#{path || "/"}?#{query}"
    end
  end
end
