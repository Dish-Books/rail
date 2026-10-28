defmodule Rail.Workflows.Utils.OpenWorkflowIssue do
  @moduledoc """
  The one way a workflow opens an issue, on schedule or by Run now. It works under a lock on the row, so a second
  click, a second tab or a scheduled start landing at the same moment waits, then finds the first one's issue
  unfinished and opens nothing.
  """

  import Ecto.Query
  import Rail.Workflows.Utils.BroadcastWorkflowsChanged

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition
  alias Rail.Workflows.Workers.StartWorkflowTask

  @doc """
  Opens `workflow`'s issue in its project's tracker, with no owner and the steps its file skips and names, and queues its
  task's start with the issue. A `:scheduled` start goes ahead only while the row is due and moves the due time on whether it opens
  anything or not; `:now` leaves the due time alone and ignores the pause.

  Returns `{:ok, issue}`, or why nothing was opened: `{:error, {:unfinished, issue}}`, `{:error, :project_inactive}`,
  `{:error, :paused}`, `{:error, :not_due}`, `{:error, :invalid}`, or the tracker's error.
  """
  def open_workflow_issue(%Workflow{id: workflow_id}, trigger) when trigger in [:scheduled, :now] do
    {:ok, {workflow, outcome}} =
      Repo.transaction(fn ->
        workflow = Repo.one!(from w in Workflow, where: w.id == ^workflow_id, lock: "FOR UPDATE")
        workflow = Repo.preload(workflow, :project)
        now = DateTime.utc_now()

        # A tracker error is committed with the due time moved on, so a failed start waits for the next one.
        outcome =
          with {:ok, date} <- start_date(workflow, trigger, now),
               :ok <- move_on(workflow, trigger, now),
               :ok <- skip(workflow, trigger),
               {:ok, issue} <-
                 Issues.create_issue(Scope.for_system(), workflow.project, %{
                   title: "#{workflow.definition.name} #{Date.to_iso8601(date)}",
                   description: workflow.definition.instructions,
                   workflow_id: workflow.id,
                   skipped_steps: workflow.definition.skip,
                   stages: workflow.definition.stages
                 }) do
            Oban.insert!(StartWorkflowTask.new(%{issue_id: issue.id}))
            {:ok, issue}
          end

        {workflow, outcome}
      end)

    case outcome do
      {:ok, %Issue{} = issue} ->
        broadcast_workflows_changed(workflow.project)
        {:ok, issue}

      {:error, reason} when reason in [:not_due, :invalid] or trigger == :now ->
        {:error, reason}

      {:error, reason} ->
        broadcast_workflows_changed(workflow.project)
        {:error, reason}
    end
  end

  # The title's date: the slot's on schedule, the day it was pressed for Run now.
  defp start_date(%Workflow{definition: nil}, _trigger, _now), do: {:error, :invalid}
  defp start_date(%Workflow{removed_at: %DateTime{}}, _trigger, _now), do: {:error, :invalid}
  defp start_date(%Workflow{}, :now, now), do: {:ok, DateTime.to_date(now)}

  defp start_date(%Workflow{next_run_at: %DateTime{} = due_at}, :scheduled, now) do
    if DateTime.after?(due_at, now), do: {:error, :not_due}, else: {:ok, DateTime.to_date(due_at)}
  end

  # Taken from now rather than from the slot, so a start missed while Rail was down runs once, not once per slot.
  defp move_on(%Workflow{}, :now, _now), do: :ok

  defp move_on(%Workflow{} = workflow, :scheduled, now) do
    {1, _rows} =
      Repo.update_all(from(w in Workflow, where: w.id == ^workflow.id),
        set: [next_run_at: Workflow.calculate_next_run_at(workflow, now), updated_at: now]
      )

    :ok
  end

  defp skip(%Workflow{paused: true}, :scheduled), do: {:error, :paused}
  defp skip(%Workflow{project: %Project{active: false}}, _trigger), do: {:error, :project_inactive}

  defp skip(%Workflow{definition: %WorkflowDefinition{}} = workflow, _trigger) do
    last =
      Repo.one(
        from i in Issue,
          where: i.workflow_id == ^workflow.id and i.project_id == ^workflow.project_id,
          order_by: [desc: i.inserted_at],
          limit: 1,
          preload: [:task]
      )

    if last != nil and not Issue.finished_state?(last.state), do: {:error, {:unfinished, last}}, else: :ok
  end
end
