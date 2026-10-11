defmodule Rail.Pipeline.Actions.ApproveTask do
  @moduledoc """
  A tech lead's Approve on Finalize: an approving review on the task's pull request from the lead's own GitHub
  account, never the app's, since an app approval would meet a review requirement no person met.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Approves `task`'s pull request as the scope's tech lead and returns `{:ok, approvals}` read after it, or
  `{:error, reason}`: `{:approve_refused, message}` when GitHub turned it down, `:no_github_token` when the lead
  has no token, and otherwise for a task not at Finalize, not marked ready, already merged or with no pull request.
  """
  def approve_task(%Scope{} = scope, %Task{} = task) do
    task = Task |> Repo.get!(task.id) |> Repo.preload(:project)

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- approvable(task),
         {:ok, %User{github_token: token, login: login} = user} <- lead(scope) do
      # Held per lead, so a second click or tab waits for the first and finds its approval rather than posting another.
      result =
        :global.trans({{:approve_task, task.id, user.id}, self()}, fn ->
          with {:ok, approvals} <- Pipeline.list_approvals(task),
               :ok <- approve(approvals, login, token, task) do
            Pipeline.list_approvals(task)
          end
        end)

      if match?({:ok, _approvals}, result),
        do: Phoenix.PubSub.broadcast(Rail.PubSub, "outputs:#{task.id}", {:approvals_changed, task.id})

      result
    end
  end

  defp lead(%Scope{user: %User{github_token: "" <> _token} = user}), do: {:ok, user}
  defp lead(%Scope{}), do: {:error, :no_github_token}

  defp approvable(%Task{} = task) do
    cond do
      task.merged_at != nil -> {:error, :merged}
      task.stage != :finalize -> {:error, {:invalid_stage, task.stage}}
      task.pr_number == nil -> {:error, :no_pull_request}
      task.marked_ready_at == nil -> {:error, :not_ready}
      true -> :ok
    end
  end

  defp approve(approvals, login, token, %Task{project: %Project{} = project} = task) do
    if Enum.any?(approvals, &(&1.login == login)) do
      :ok
    else
      case GitHub.approve_pull_request(token, project.github_repo, task.pr_number) do
        {:ok, _review} -> :ok
        {:error, reason} -> {:error, {:approve_refused, message(reason)}}
      end
    end
  end

  # GitHub puts why it refused a review in its errors list, under a message as general as "Unprocessable Entity".
  defp message({:github_api_error, _status, %{"message" => "" <> message} = body}) do
    errors = for error <- List.wrap(body["errors"]), "" <> text <- [error_text(error)], do: text
    Enum.join([message | errors], ": ")
  end

  defp message({:github_api_error, status, _body}), do: "GitHub answered #{status}."
  defp message(reason), do: if(is_exception(reason), do: Exception.message(reason), else: inspect(reason))

  defp error_text("" <> text), do: text
  defp error_text(%{"message" => "" <> text}), do: text
  defp error_text(_unknown), do: nil
end
