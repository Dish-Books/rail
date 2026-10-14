defmodule Rail.Pipeline.Utils.StartChecks do
  @moduledoc """
  Starts the agents that check a round's change once it is pushed. QA and the code reviewer start together, each a
  run of its own on a clean conversation. The screenshots agent and the demo recorder follow QA one at a time when
  the round's plan asks for them, since the three that drive the app share the worktree's one server, and the
  review agent follows them all but the demo.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Starts QA and the code reviewer on `task`, with last round's reports from them cleared and every checking run
  open again. Returns `:ok`. A project with neither role has nothing to start.
  """
  def start_checks(%Task{} = task) do
    for role <- [:qa, :review], do: File.rm(Path.join([task.scratch_path, "reports", "#{role}.md"]))

    # A run done in the last round reads as not done in this one, so nothing waiting on it starts early.
    Repo.update_all(
      from(r in Run,
        join: role in assoc(r, :role),
        where: r.task_id == ^task.id and role.stage in [:qa, :review, :screens, :review_lead]
      ),
      set: [stage_outcome: :in_progress]
    )

    for stage <- [:qa, :review],
        {:ok, %Role{} = role} <- [Roles.get_role(project_id: task.project_id, stage: stage)] do
      {:ok, %Run{}} = start_role_run(task, role, fresh: true)
    end

    :ok
  end
end
