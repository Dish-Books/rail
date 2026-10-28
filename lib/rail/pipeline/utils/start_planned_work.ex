defmodule Rail.Pipeline.Utils.StartPlannedWork do
  @moduledoc """
  Starts the work a task's plan describes, as approving it or starting without approval both do: the ticket, with
  its priority and estimate, and the picked design are published to the issue, and the task moves to Engineer,
  where a `StartEngineer` job committed with the move starts the engineer. Unsent plan comments are deleted, since
  the conversation they would go to closes. Nothing starts while a question waits on an answer.

  Starting is a one-way door. The task row is locked and the next stage claimed inside the same transaction, so a
  second click or a second tab waits on the lock, then finds the task moved on and is refused before anything is
  published or created again.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPlanComments
  import Rail.Pipeline.Utils.CheckAnswered
  import Rail.Pipeline.Utils.CheckPlan

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Starts the work of the plan the Plan `run` saved, once `allowed.(task, round)` says `:ok`, marking its round
  `:approved` or `:ready` as the scope's user. Returns `{:ok, run}`, the run latched done, or `{:error, reason}`.
  """
  def start_planned_work(%Scope{} = scope, %Run{} = run, mark, allowed)
      when mark in [:approved, :ready] and is_function(allowed, 2) do
    result =
      Repo.transaction(fn ->
        task = Repo.one!(from t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")
        task = Repo.preload(task, [:runs, issue: [], project: :linear_workspace])

        with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
             :ok <- startable(task),
             :ok <- check_answered(task),
             {:ok, %Round{} = round, design} <- check_plan(task),
             :ok <- allowed.(task, round),
             :ok <- publish(task, round.ticket, design) do
          {:ok, _marked} = round |> marked(mark, scope.user && scope.user.id) |> Repo.update()

          authors = delete_unsent_comments(task)
          {:ok, run} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
          {:ok, task} = Pipeline.enter_stage(task, :engineer, start: false)
          # Committed with the move, so the start does not depend on the caller outliving it.
          {:ok, _job} = Oban.insert(StartEngineer.new(%{task_id: task.id}))
          {run, task, authors}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    announce(result)
  end

  defp announce({:ok, {run, task, authors}}) do
    for user_id <- authors, do: broadcast_plan_comments(task.id, user_id)
    {:ok, run}
  end

  defp announce({:error, reason}), do: {:error, reason}

  defp marked(%Round{} = round, :approved, user_id), do: Round.approve_changeset(round, user_id)
  defp marked(%Round{} = round, :ready, user_id), do: Round.ready_changeset(round, user_id)

  defp startable(%Task{stage: stage}) when stage != :plan, do: {:error, {:invalid_stage, stage}}

  defp startable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  # Returns whose comments went, so only their tabs are told.
  defp delete_unsent_comments(%Task{id: task_id}) do
    {_deleted, authors} =
      Repo.delete_all(
        from(comment in PlanComment,
          where: comment.task_id == ^task_id and comment.status == :unsent,
          select: comment.user_id
        )
      )

    Enum.uniq(authors)
  end

  # One write carries the ticket and the design. The tracker hears about it from the sync that write enqueues.
  # With Product off the issue is the ticket, so nothing of it is written back over what the tracker has now.
  defp publish(%Task{issue: %Issue{skipped_steps: skipped} = issue} = task, ticket, design) do
    if :product in skipped,
      do: publish_design(task, %{title: nil, description: issue.description, priority: nil, estimate: nil}, design),
      else: publish_design(task, ticket, design)
  end

  defp publish_design(%Task{}, %{title: nil}, nil), do: :ok

  defp publish_design(%Task{issue: %Issue{} = issue}, ticket, nil) do
    update_issue(issue, ticket_attrs(ticket, ticket.description))
  end

  # A tracker that cannot hold the screenshot, such as GitHub Issues, still gets the design's text.
  defp publish_design(%Task{issue: %Issue{} = issue} = task, ticket, {option, screenshot}) do
    uploaded =
      case Issues.upload_asset(task.project, "#{issue.identifier}-#{option.key}.png", "image/png", screenshot) do
        {:error, :unsupported} -> {:ok, nil}
        result -> result
      end

    with {:ok, asset_url} <- uploaded do
      image = if asset_url, do: "\n\n![#{option.title}](#{asset_url})", else: ""
      section = String.trim("## Design: #{option.title}\n\n#{option.summary}") <> image
      description = String.trim(ticket.description || "")
      description = if description == "", do: section, else: description <> "\n\n" <> section

      update_issue(issue, ticket_attrs(ticket, description))
    end
  end

  # A priority or estimate the ticket has none of is left as the issue has it.
  defp ticket_attrs(ticket, description) do
    Map.reject(
      %{title: ticket.title, description: description, priority: ticket.priority, estimate: ticket.estimate},
      fn {_field, value} -> is_nil(value) end
    )
  end

  defp update_issue(%Issue{} = issue, attrs) do
    case Issues.update_issue(issue, attrs) do
      {:ok, _issue} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
