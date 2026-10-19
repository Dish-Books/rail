defmodule Rail.Pipeline.Actions.ApproveFixPlan do
  @moduledoc """
  Approves the plan the review agent saved for the next round, the only thing that starts its changes: the plan
  becomes the task's next round, approved, and the task goes back to Engineer, where a `StartEngineer` job
  committed with the move starts the engineer on it with a clean conversation. Only the version the person read,
  still waiting, is approved, and the comments left unsent on it go. Anyone who can open the project approves a
  later round's plan. A plan that changes
  the ticket, as a person asked, puts the new ticket on its round and on the issue.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.BroadcastPlanComments
  import Rail.Pipeline.Utils.CheckAnswered
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.PlanComment
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
  anything works on the task, `{:unanswered_questions, count}` while questions wait on an answer.
  """
  def approve_fix_plan(%Scope{} = scope, %Run{} = run, version) when is_integer(version) do
    result =
      Repo.transaction(fn ->
        # Of two Approves the second waits here, then finds the plan approved.
        task = Repo.one!(from t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")
        task = Repo.preload(task, [:issue, :project, :runs])

        with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
             false <- Task.running?(task) && {:error, :stage_running},
             :ok <- check_answered(task),
             %FixPlan{} = fix_plan <- Pipeline.read_fix_plan(task) || {:error, :no_fix_plan},
             :ok <- latest(fix_plan, version),
             :waiting <- waiting(FixPlan.state(fix_plan, task, Pipeline.list_findings(task))) do
          {approve(scope, task, fix_plan), drop_unsent_comments(task)}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {%Task{} = task, authors}} <- result do
      broadcast_pipeline_changed(task)
      Enum.each(authors, &broadcast_plan_comments(task.id, &1))
      {:ok, Repo.get!(Run, run.id)}
    end
  end

  # A comment left unsent on the plan was for a change to it, which approving it has passed, so it goes with it.
  # Its authors' trays are told it went.
  defp drop_unsent_comments(%Task{id: task_id}) do
    {_count, authors} =
      Repo.delete_all(
        from(comment in PlanComment,
          where: comment.task_id == ^task_id and comment.target == :fix_plan and comment.status == :unsent,
          select: comment.user_id
        )
      )

    Enum.uniq(authors)
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

  # The tracker's ticket follows: the description as the plan changed it, and below it the design section approval
  # added, or the picked design's new picture when the plan changed the design.
  defp publish(%Task{}, %Round{}, %FixPlan{title: nil, description: nil, design_changed: false}), do: :ok

  defp publish(%Task{issue: %Issue{} = issue} = task, %Round{}, %FixPlan{} = fix_plan) do
    [description | section] = String.split(issue.description || "", "\n\n## Design: ", parts: 2)

    design =
      if fix_plan.design_changed,
        do: design_section(task),
        else: Enum.map_join(section, &("\n\n## Design: " <> &1))

    attrs = %{title: fix_plan.title, description: (fix_plan.description || description) <> design}
    {:ok, _issue} = Issues.update_issue(issue, Map.reject(attrs, fn {_field, value} -> is_nil(value) end))
    :ok
  end

  # A tracker that cannot hold the picture, such as GitHub Issues, still gets the design's text.
  defp design_section(%Task{issue: %Issue{} = issue, project: project} = task) do
    case Pipeline.read_design(task, pages: false) do
      %{picked: key, options: options} when is_binary(key) ->
        option = Enum.find(options, &(&1.key == key))
        screenshot = File.read!(Path.join([task.scratch_path, "design", "#{key}.png"]))

        image =
          case Issues.upload_asset(project, "#{issue.identifier}-#{key}.png", "image/png", screenshot) do
            {:ok, url} -> "\n\n![#{option.title}](#{url})"
            {:error, _unsupported} -> ""
          end

        "\n\n" <> String.trim("## Design: #{option.title}\n\n#{option.summary}") <> image

      _no_pick ->
        ""
    end
  end
end
