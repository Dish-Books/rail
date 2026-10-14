defmodule Rail.Pipeline.Actions.ApproveFixPlan do
  @moduledoc """
  Approves the plan the review agent saved for the next round, the only thing that starts its changes: the plan
  becomes the task's next round, approved, and the task goes back to Engineer, where a `StartEngineer` job
  committed with the move starts the engineer on it with a clean conversation. Only the version the person read,
  still waiting, is approved. Anyone who can open the project approves a later round's plan. A plan that changes
  the ticket, as a person asked, puts the new ticket on its round and on the issue.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Approves version `version` of the fix plan on `run`, the task's review run, as the scope's user, and queues the
  engineer's start. Returns `{:ok, run}`, or `{:error, reason}`: `{:fix_plan_replaced, saved_at}` when a later
  version was saved, `{:fix_plan_not_waiting, state}` when it is not waiting on approval, `:stage_running` while
  anything works on the task.
  """
  def approve_fix_plan(%Scope{} = scope, %Run{} = run, version) when is_integer(version) do
    result =
      Repo.transaction(fn ->
        # Of two Approves the second waits here, then finds the plan approved.
        task = Repo.one!(from t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")
        task = Repo.preload(task, [:issue, :project, :runs])

        with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
             false <- Task.running?(task) && {:error, :stage_running},
             %FixPlan{} = fix_plan <- Pipeline.read_fix_plan(task) || {:error, :no_fix_plan},
             :ok <- latest(fix_plan, version),
             :waiting <- waiting(FixPlan.state(fix_plan, task, Pipeline.list_findings(task))) do
          approve(scope, task, fix_plan)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, %Task{} = task} <- result do
      broadcast_pipeline_changed(task)
      {:ok, Repo.get!(Run, run.id)}
    end
  end

  defp latest(%FixPlan{version: version}, version), do: :ok
  defp latest(%FixPlan{saved_at: saved_at}, _read), do: {:error, {:fix_plan_replaced, saved_at}}

  defp waiting(:waiting), do: :waiting
  defp waiting(state), do: {:error, {:fix_plan_not_waiting, state}}

  # The round, the move and the job commit together, so an approved plan always has an engineer to start.
  defp approve(%Scope{user: user}, %Task{} = task, %FixPlan{} = fix_plan) do
    {:ok, round} = Pipeline.create_round(task)

    {:ok, approved} =
      round
      |> Round.approve_changeset(user && user.id)
      |> Ecto.Changeset.change(
        plan: fix_plan.plan,
        plan_version: fix_plan.version,
        plan_saved_at: fix_plan.saved_at,
        record_demo: fix_plan.record_demo,
        retake_screens: fix_plan.retake_screens,
        base_head: fix_plan.head
      )
      |> amend(fix_plan)
      |> Repo.update()

    :ok = publish(task, approved, fix_plan)

    # A task a teammate marked ready has changes coming, so it is not ready any more.
    {:ok, task} = task |> Task.changeset(%{marked_ready_at: nil, marked_ready_by_id: nil}) |> Repo.update()
    {:ok, task} = Pipeline.enter_stage(task, :engineer, start: false)
    {:ok, _job} = Oban.insert(StartEngineer.new(%{task_id: task.id}))

    name = if user, do: user.name || user.login, else: "Rail"
    :ok = write_fix_plan(task, %{fix_plan | approved_by: name, approved_at: DateTime.utc_now()})
    task
  end

  # The round carries the ticket as the plan changed it, so every agent after reads the criteria as they now stand.
  defp amend(changeset, %FixPlan{title: nil, description: nil}), do: changeset

  defp amend(changeset, %FixPlan{} = fix_plan) do
    ticket = Ecto.Changeset.get_field(changeset, :ticket) || %Round.Ticket{}

    Ecto.Changeset.put_embed(changeset, :ticket, %{
      Map.from_struct(ticket)
      | title: fix_plan.title || ticket.title,
        description: fix_plan.description || ticket.description
    })
  end

  # The tracker's ticket follows, keeping the design section approval added below the description.
  defp publish(%Task{}, %Round{}, %FixPlan{title: nil, description: nil}), do: :ok

  defp publish(%Task{issue: %Issue{} = issue}, %Round{}, %FixPlan{} = fix_plan) do
    design =
      case String.split(issue.description || "", "\n\n## Design: ", parts: 2) do
        [_description, section] -> "\n\n## Design: " <> section
        [_none] -> ""
      end

    attrs = %{title: fix_plan.title, description: fix_plan.description && fix_plan.description <> design}
    {:ok, _issue} = Issues.update_issue(issue, Map.reject(attrs, fn {_field, value} -> is_nil(value) end))
    :ok
  end
end
