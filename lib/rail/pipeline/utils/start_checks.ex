defmodule Rail.Pipeline.Utils.StartChecks do
  @moduledoc """
  Starts the agents that check a round's change once it is pushed, all together, each a run of its own on a clean
  conversation: QA, the code reviewer, and the screenshots agent and the demo recorder when the round's plan asks
  for them. Each that drives the app has a browser of its own on the worktree's one server. The review agent
  follows them all but the demo.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Starts QA, the code reviewer and what the round's plan asks for on `task`, with last round's reports from them
  cleared and every checking run open again. Returns `:ok`. A role the project does not have starts nothing.
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

    for stage <- [:qa, :review | asked(Pipeline.read_plan(task))],
        {:ok, %Role{} = role} <- [Roles.get_role(project_id: task.project_id, stage: stage)] do
      {:ok, %Run{}} = start_role_run(task, role, fresh: true)
    end

    :ok
  end

  # The screens are shot again and a demo recorded only when the round's plan asks.
  defp asked(%Round{} = round),
    do: for({stage, true} <- [screens: round.retake_screens, demo: round.record_demo], do: stage)

  defp asked(nil), do: []
end
