defmodule Rail.Pipeline.Actions.CreateTask do
  @moduledoc """
  Creates the pipeline task for an issue, at the stage it should start from.

  The task carries only its own pipeline state: the title, description and
  owner stay on the issue it links to. The issue's own state is left alone -
  starting a stage is what moves its tracker status forward. Returns the existing
  task when the issue already has one. A cleaned-up task does not count: it is
  kept as history and the issue gets a fresh one.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Creates or returns the task for `issue`, starting it at `stage`.
  """
  def create_task(%Issue{project: %Project{} = project} = issue, stage) do
    case Repo.one(from(t in Task, where: t.issue_id == ^issue.id and is_nil(t.cleaned_up_at))) do
      %Task{} = task -> {:ok, task}
      nil -> project |> build_task(issue, %{stage: stage}) |> Repo.insert()
    end
  end
end
