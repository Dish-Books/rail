defmodule Rail.Pipeline.Utils.CheckRunFinished do
  @moduledoc """
  Where a finished checking run leaves its round. QA and the code reviewer owe a report. All of them started
  together, so the last of QA, the code reviewer and a screenshots agent the plan asked for to finish starts the
  review agent, which does not wait on the demo.

  The run is latched done here, under the task's lock, so of two that finish together one sees the other done.
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

  @checks [:qa, :review, :screens]

  @doc "Finishes `run` as QA's, the code reviewer's or the screenshots agent's."
  def check_run_finished(%Run{role: %Role{stage: stage}, task: %Task{} = task} = run, _opts) when stage in @checks do
    if stage in [:qa, :review] and not Keyword.has_key?(Pipeline.read_reports(task), stage) do
      fail(run, "#{name(stage)} did not save its report.")
    else
      {:ok, {done, last?}} =
        Repo.transaction(fn ->
          Repo.one!(from t in Task, where: t.id == ^task.id, select: t.id, lock: "FOR UPDATE")
          {:ok, done} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
          {done, waiting(task) == []}
        end)

      # Outside the transaction, since a spawn reads its run from another process.
      with true <- last?, {:ok, %Role{} = role} <- Roles.get_role(project_id: task.project_id, stage: :review_lead) do
        {:ok, %Run{}} = start_role_run(task, role, fresh: true)
      end

      %{done | task: run.task, role: run.role}
    end
  end

  defp waiting(%Task{} = task) do
    stages = Repo.all(from role in Role, where: role.project_id == ^task.project_id, select: role.stage)

    done =
      Repo.all(
        from r in Run,
          join: role in assoc(r, :role),
          where: r.task_id == ^task.id and r.stage_outcome == :done,
          select: role.stage
      )

    # A role the project does not have checks nothing, so nothing waits on it.
    Enum.reject([:qa, :review | screens(Pipeline.read_plan(task))], &(&1 in done or &1 not in stages))
  end

  # The screens are shot again only when the round's plan asks.
  defp screens(%Round{retake_screens: true}), do: [:screens]
  defp screens(_round), do: []

  defp name(:qa), do: "QA"
  defp name(:review), do: "The code reviewer"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
