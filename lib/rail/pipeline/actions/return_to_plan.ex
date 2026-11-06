defmodule Rail.Pipeline.Actions.ReturnToPlan do
  @moduledoc """
  Back to Plan, Discard's other choice: erases the work as Discard does but keeps the task with its ticket, design,
  plan and the custom stages before Plan, and starts the Planner on them on a new conversation.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.ClearBranch
  import Rail.Pipeline.Utils.StageOutputPath

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Takes `task` back to Plan on behalf of `scope` and returns `{:ok, task}` as it now stands. Refuses as Discard
  does, and with `:not_discardable` for a task at Plan or one whose first round holds no plan.
  """
  def return_to_plan(%Scope{} = scope, %Task{} = task) do
    clear_branch(scope, task, &returnable/1, &rewind(scope, &1))
  end

  defp returnable(%Task{stage: stage, rounds: rounds}) do
    if stage != :plan and match?(%Round{plan: "" <> _plan}, Enum.find(rounds, &(&1.number == 1))),
      do: :ok,
      else: {:error, :not_discardable}
  end

  # Retry and Re-record start runs without the task's lock, so one may have started while GitHub answered.
  # What is on disk cannot be rolled back, so it goes next; the rows then land together or not at all.
  defp rewind(scope, %Task{id: task_id, issue: issue} = task) do
    for run <- Repo.preload(task, :runs, force: true).runs,
        Run.running?(run),
        do: {:ok, _stopped, _queued} = Pipeline.stop_run(scope, run)

    :ok = Tools.stop_browser_session(task)
    sequence = Issue.calculate_stages(issue)

    # A custom stage before Plan is what Plan was given, so its approved run, file and comments stay, as the design does.
    kept =
      if :plan in sequence, do: for({:custom, name} <- Enum.take_while(sequence, &(&1 != :plan)), do: name), else: []

    remove_work(task, kept)

    {:ok, planning} =
      Repo.transaction(fn ->
        kept_roles =
          from(role in Role, where: role.project_id == ^task.project_id and role.custom_stage in ^kept, select: role.id)

        # A run's processes, events, questions and retrievals cascade from it.
        Repo.delete_all(from(r in Run, where: r.task_id == ^task_id and r.role_id not in subquery(kept_roles)))
        Repo.delete_all(from(r in Round, where: r.task_id == ^task_id and r.number > 1))
        task.rounds |> Enum.find(&(&1.number == 1)) |> Round.return_to_plan_changeset() |> Repo.update!()

        for schema <- [FindingComment, DiffComment, ScreenComment, Finding],
            do: Repo.delete_all(from(row in schema, where: row.task_id == ^task_id))

        Repo.delete_all(
          from(c in PlanComment,
            where:
              c.task_id == ^task_id and
                (c.target != :output or is_nil(c.custom_stage) or c.custom_stage not in ^kept)
          )
        )

        :ok = Git.delete_viewed_files(task)
        {:ok, _reset} = reset_ticket(issue)
        task |> Task.return_to_plan_changeset() |> Repo.update!()
      end)

    # The cleared slot and setup are what the Planner's start reads, so the worktree is made and set up afresh.
    {:ok, %Run{}} = Pipeline.enter_stage(planning, :plan, fresh: true)
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
    broadcast_pipeline_changed(planning)
    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    # An adopted pull request is closed now, so the issue lets its link go.
    if is_integer(issue.pr_number), do: Issues.link_pull_request(scope, Repo.reload!(issue))
    {:ok, Repo.reload!(planning)}
  end

  # The design folder is the picked design's pages, which Plan carries on from, as it does the kept stages' files.
  defp remove_work(%Task{project: project, scratch_path: scratch_path} = task, kept) do
    if is_binary(project.clone_path) do
      Git.remove_worktree(project.clone_path, task.worktree_path)
      Git.delete_branch(project.clone_path, task.worktree_name)
    end

    for path <- Path.wildcard(Path.join(scratch_path, "*"), match_dot: true),
        Path.basename(path) not in ["design", "stages"],
        do: File.rm_rf!(path)

    for {%IssueStage{stage: :custom, name: name}, position} <- Enum.with_index(task.issue.stages, 1),
        name not in kept,
        do: File.rm_rf!(stage_output_path(task, position, name))
  end

  defp reset_ticket(%Issue{state: state} = issue) do
    if Issue.finished_state?(state), do: {:ok, issue}, else: Issues.reset_issue_state(issue, :in_progress)
  end
end
