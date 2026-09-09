defmodule RailTest.PipelineHelpers do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  def create_test_project(attrs \\ %{}) do
    RailTest.RolesHelpers.create_test_project(attrs)
  end

  def create_test_task(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    project_id = attrs[:project_id] || attrs["project_id"] || create_test_project().id

    default_attrs = %{
      title: "Task #{id}",
      description: "Description for task #{id}",
      stage: :product,
      stage_state: :queued,
      worktree_name: "task-#{id}"
    }

    merged = Map.merge(default_attrs, attrs)

    %Task{}
    |> Task.changeset(merged, project_id)
    |> Repo.insert!()
  end

  def create_test_question(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    task_id = attrs[:task_id] || attrs["task_id"] || create_test_task().id

    default_attrs = %{
      prompt: "Question prompt #{id}?",
      options: ["Yes", "No"],
      status: :pending
    }

    merged = Map.merge(default_attrs, attrs)

    %Question{}
    |> Question.changeset(merged, task_id)
    |> Repo.insert!()
  end

  def create_test_plan(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    task_id = attrs[:task_id] || attrs["task_id"] || create_test_task().id

    default_attrs = %{
      content: "# Plan #{id}\nContent here",
      captured_at: DateTime.utc_now()
    }

    merged = Map.merge(default_attrs, attrs)

    %Plan{}
    |> Plan.changeset(merged, task_id)
    |> Repo.insert!()
  end
end
