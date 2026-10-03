defmodule Rail.Pipeline.Actions.MarkPullRequestReady do
  @moduledoc """
  Takes a task's draft pull request out of draft, when a person says so, and
  posts each open question for the lead on it as a comment of its own.

  The description is never touched here, so a description still being written
  in the background lands after the pull request is ready.
  """

  import Ecto.Query

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  require Logger

  @doc """
  Marks `task`'s draft pull request ready for review. Returns `{:ok, task}`,
  `{:error, :not_markable}` when `Task.ready_to_mark?/1` says no, or the error
  GitHub gave.
  """
  def mark_pull_request_ready(%Scope{}, %Task{} = task) do
    query =
      from(t in Task, where: t.id == ^task.id and t.project_id == ^task.project_id, preload: [:project, runs: :role])

    %Task{project: %Project{} = project} = task = Repo.one!(query)

    with true <- Task.ready_to_mark?(task) || {:error, :not_markable},
         {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, pull_request} <- GitHub.get_pull_request(token, project.github_repo, task.pr_number),
         :ok <- mark_on_github(token, pull_request) do
      out_of_draft = from(t in Task, where: t.id == ^task.id and t.pr_is_draft == true)

      # Only the press that flips the flag posts, so a double click cannot post twice.
      case Repo.update_all(out_of_draft, set: [pr_is_draft: false, updated_at: DateTime.utc_now()]) do
        {1, _rows} -> post_open_questions(token, project, task)
        {0, _rows} -> :ok
      end

      {:ok, Repo.reload!(task)}
    end
  end

  # Someone may have readied it on GitHub already, which leaves Rail only to catch up.
  defp mark_on_github(token, %{"draft" => true, "node_id" => node_id}), do: GitHub.mark_pull_request_ready(token, node_id)
  defp mark_on_github(_token, %{}), do: :ok

  defp post_open_questions(token, %Project{} = project, %Task{} = task) do
    questions = Pipeline.list_questions(task, status: [:pending, :unanswered], order_by: [asc: :inserted_at])

    assumptions =
      case Pipeline.get_implementation_plan(task) do
        {:ok, %ImplementationPlan{} = plan} -> ImplementationPlan.assumptions(plan)
        {:error, :not_found} -> []
      end

    comments =
      Enum.map(questions, &question_comment/1) ++
        Enum.map(assumptions, &"**Assumption in the approved plan, for the lead to confirm**\n\n#{&1}")

    Enum.each(comments, fn body ->
      case GitHub.create_issue_comment(token, project.github_repo, task.pr_number, body) do
        {:ok, _comment} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not comment on #{project.github_repo}##{task.pr_number}: #{inspect(reason)}")
      end
    end)
  end

  defp question_comment(%Question{prompt: prompt, context_summary: context, options: options}) do
    bullets =
      [context | Enum.map(options, &"Option: #{&1}")]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map_join("\n", &"- #{&1}")

    String.trim("**Open question for the lead**\n\n#{prompt}\n\n#{bullets}")
  end
end
