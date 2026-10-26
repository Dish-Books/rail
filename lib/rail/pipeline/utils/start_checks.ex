defmodule Rail.Pipeline.Utils.StartChecks do
  @moduledoc """
  Starts the agents that check a round's change once it is pushed, all together, each a run of its own on a clean
  conversation: QA, the code reviewer, and the demo recorder when the round's plan asks for it. Each that drives the
  app has a browser of its own on the worktree's one server. The review agent
  follows them all but the demo.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.PrepareWorktree
  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Starts QA, the code reviewer and what the round's plan asks for on `task`, with last round's reports from them
  cleared and every checking run open again. Returns `:ok`. A role the project does not have starts nothing.
  While setup is pending only the first starts, and its setup the rest. `except:` checks are left as they are.
  """
  def start_checks(%Task{} = task, opts \\ []) do
    checks = Task.check_stages() -- Keyword.get(opts, :except, [])

    for role <- checks, do: File.rm(Path.join([task.scratch_path, "reports", "#{role}.md"]))

    # A run done in the last round reads as not done in this one, so nothing waiting on it starts early.
    Repo.update_all(
      from(r in Run,
        join: role in assoc(r, :role),
        where: r.task_id == ^task.id and role.stage in ^[:review_lead | checks]
      ),
      set: [stage_outcome: :in_progress]
    )

    {task, setup_pending?} = prepare(task)

    roles =
      for stage <- checks ++ asked(Pipeline.read_plan(task)),
          {:ok, %Role{} = role} <- [Roles.get_role(project_id: task.project_id, stage: stage)],
          do: role

    # Each run would start a setup of its own on the one worktree, so the first carries it alone.
    roles = if setup_pending?, do: Enum.take(roles, 1), else: roles

    for role <- roles, do: {:ok, %Run{}} = start_role_run(task, role, fresh: true)

    :ok
  end

  # Prepared once, so every run shares the one slot; a worktree that cannot be made fails each run on its own.
  defp prepare(%Task{} = task) do
    with %Project{} = project <- Repo.get(Project, task.project_id),
         {:ok, %Task{} = prepared, _worktree_path} <- prepare_worktree(project, task) do
      {prepared, prepared.worktree_setup_at == nil and project.worktree_setup_script not in [nil, ""]}
    else
      _unavailable -> {task, false}
    end
  end

  # A demo is recorded only when the round's plan asks.
  defp asked(%Round{record_demo: true}), do: [:demo]
  defp asked(_round), do: []
end
