defmodule Rail.Pipeline.Actions.CreateChildTask do
  @moduledoc """
  Creates one child of a split at Engineer, under its parent, with its part of the parent's plan as the plan
  it builds from. A child marked as building the screen gets the parent's design in its scratch, where Engineer reads it.
  """

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Inserts the task for `issue` as `child` of `parent`, `child` being one of `read_split/1`'s children.
  Returns `{:ok, task}` or `{:error, changeset}`; nothing is started.
  """
  def create_child_task(%Task{} = parent, %Issue{project: %Project{} = project} = issue, child) do
    attrs = %{stage: :engineer, split_position: child.number, builds_on: child.builds_on}

    with {:ok, task} <-
           project |> build_task(issue, attrs) |> Ecto.Changeset.put_change(:parent_task_id, parent.id) |> Repo.insert(),
         {:ok, _plan} <-
           %ImplementationPlan{}
           |> ImplementationPlan.changeset(%{task_id: task.id, content: child.plan, captured_at: DateTime.utc_now()})
           |> Repo.insert() do
      design = Path.join(parent.scratch_path, "design")

      if child.builds_screen and File.dir?(design) do
        File.mkdir_p!(task.scratch_path)
        File.cp_r!(design, Path.join(task.scratch_path, "design"))
      end

      {:ok, task}
    end
  end
end
