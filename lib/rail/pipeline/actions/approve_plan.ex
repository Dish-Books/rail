defmodule Rail.Pipeline.Actions.ApprovePlan do
  @moduledoc """
  Approves the Plan step in one go: the ticket, with its priority and estimate, and the picked design are
  published to the issue, the plan is recorded as the one the engineer builds from, and the task moves to
  Engineer. With a split saved, each child becomes a Linear sub-issue with a task of its own instead, the parent
  moves to Split, and an `AdvanceSplit` job committed with them starts the children, so they start even if the
  caller dies. Unsent plan comments are deleted, since the conversation they would go to closes.

  Approving is a one-way door. The task row is locked and the next stage claimed inside the same
  transaction, so a second click or a second tab waits on the lock, then finds the task moved on and is
  refused before anything is published or created again.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.BroadcastPlanComments
  import Rail.Pipeline.Utils.RecordImplementationPlan

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Approves what the Plan `run` saved and enters Engineer, or with a split, queues the start of each
  child that builds on no other.

  Returns `{:ok, run}`, the run latched done.
  """
  def approve_plan(%Scope{} = scope, %Run{} = run) do
    result =
      Repo.transaction(fn ->
        task = Repo.one!(from t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")
        task = Repo.preload(task, [:runs, issue: [], project: :linear_workspace])

        with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
             :ok <- approvable(task),
             {:ok, ticket} <- ticket(task),
             {:ok, plan} <- plan(task),
             {:ok, design} <- design(task, plan),
             :ok <- publish(task, ticket, design),
             {:ok, children} <- create_children(scope, task, Pipeline.read_split(task)) do
          record_implementation_plan(task, plan.content)
          authors = delete_unsent_comments(task)
          {:ok, run} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
          {:ok, task} = Pipeline.enter_stage(task, if(children == [], do: :engineer, else: :split), start: false)
          if children != [], do: {:ok, _job} = %{parent_task_id: task.id} |> AdvanceSplit.new() |> Oban.insert()
          {run, task, children, authors}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {_run, task, _children, authors}} <- result do
      for user_id <- authors, do: broadcast_plan_comments(task.id, user_id)
    end

    # Started only once the move is committed, so the engineer's spawn reads the task at Engineer.
    case result do
      {:ok, {run, task, [], _authors}} ->
        with {:ok, _started} <- Pipeline.enter_stage(task, :engineer), do: {:ok, run}

      # The move to Split was broadcast inside the transaction, so a page that read it then missed the children.
      {:ok, {run, task, children, _authors}} ->
        broadcast_pipeline_changed(task)

        for child <- children, do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, child.issue_id})

        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp approvable(%Task{stage: stage}) when stage != :plan, do: {:error, {:invalid_stage, stage}}

  defp approvable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  defp ticket(%Task{} = task) do
    case Pipeline.read_ticket(task) do
      %{} = ticket -> {:ok, ticket}
      nil -> {:error, :no_ticket}
    end
  end

  defp plan(%Task{} = task) do
    case Pipeline.read_plan(task) do
      %{} = plan -> {:ok, plan}
      nil -> {:error, :no_plan}
    end
  end

  # With no options there is no screen, and the ticket goes out alone.
  defp design(%Task{} = task, plan) do
    written_for = plan.design && plan.design.key

    case Pipeline.read_design(task, pages: false) do
      %{options: []} -> {:ok, nil}
      %{picked: nil} -> {:error, :nothing_picked}
      %{picked: ^written_for, options: options} -> options |> Enum.find(&(&1.key == written_for)) |> screenshot()
      %{picked: _other} -> {:error, :plan_not_for_pick}
      nil -> {:ok, nil}
    end
  end

  # The screenshot is the published thing, so one older than its page would publish a design nobody approved.
  defp screenshot(option) do
    with {:ok, %File.Stat{mtime: html_mtime}} <- File.stat(option.html_path, time: :posix),
         {:ok, %File.Stat{mtime: screenshot_mtime}} <- File.stat(option.screenshot_path, time: :posix) do
      if screenshot_mtime >= html_mtime,
        do: {:ok, {option, File.read!(option.screenshot_path)}},
        else: {:error, :stale_screenshot}
    else
      {:error, _missing} -> {:error, :screenshot_missing}
    end
  end

  # One write carries the ticket and the design. The tracker hears about it from the sync that write enqueues.
  defp publish(%Task{issue: %Issue{} = issue}, ticket, nil) do
    update_issue(issue, ticket_attrs(ticket, ticket.description))
  end

  # A tracker that cannot hold the screenshot, such as GitHub Issues, still gets the design's text.
  defp publish(%Task{issue: %Issue{} = issue} = task, ticket, {option, screenshot}) do
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

  # A priority or estimate the ticket could not be read with is left as the issue has it.
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

  defp create_children(%Scope{}, %Task{}, nil), do: {:ok, []}

  # In order, so a child's sub-issue is never made before the ones it builds on.
  defp create_children(%Scope{} = scope, %Task{issue: %Issue{} = parent_issue} = task, %{children: children}) do
    children
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, created} ->
      attrs = %{
        title: child.title,
        description: child.ticket,
        estimate: child.estimate,
        priority: parent_issue.priority,
        owner_user_id: parent_issue.owner_user_id,
        parent: parent_issue
      }

      with {:ok, issue} <- Issues.create_issue(scope, task.project, attrs),
           {:ok, child_task} <- Pipeline.create_child_task(task, issue, child) do
        {:cont, {:ok, [child_task | created]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, created} -> {:ok, Enum.reverse(created)}
      {:error, reason} -> {:error, reason}
    end)
  end
end
