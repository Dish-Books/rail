defmodule Rail.Pipeline.Utils.StartChecks do
  @moduledoc """
  Starts the agents that check a round's change once it is pushed, all together, each a run of its own on a clean
  conversation: QA, the code reviewer, and the demo recorder when the round's plan asks for it and the task's workflow
  left the demo on. Each that drives the
  app has a browser of its own on the worktree's one server. The review agent
  follows them all but the demo.

  A round after the first that changed only files the project says nobody sees in the app, such as tests and docs,
  gets the code reviewer alone. Its QA run is marked skipped, which the review agent does not wait on, and QA's report
  says why in one line. A person can still start QA on the round from the task page.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.MatchesGlob
  import Rail.Pipeline.Utils.PrepareWorktree
  import Rail.Pipeline.Utils.RoundChange
  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  # Enough to show what the round was, short enough to stay one line.
  @named 10

  @doc """
  Starts QA, the code reviewer and what the round's plan asks for on `task`, with last round's reports from them
  cleared and every checking run open again. Returns `:ok`. A role the project does not have starts nothing.
  While setup is pending only the first starts, and its setup the rest. `except:` stages are left as they are.
  """
  def start_checks(%Task{} = task, opts \\ []) do
    except = Keyword.get(opts, :except, [])
    checks = Task.check_stages() -- except

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

    stages =
      case unseen(task) do
        %{number: number, paths: paths} ->
          skip_qa(task, number, paths)
          [:review]

        nil ->
          [:qa, :review | asked(Repo.preload(task, :issue).issue, Pipeline.read_plan(task))]
      end

    roles =
      for stage <- stages -- except,
          {:ok, %Role{} = role} <- [Roles.get_role(project_id: task.project_id, stage: stage)],
          do: role

    # A worktree not set up yet holds every check back: the first sets it up, and the setup's finish starts the rest.
    for role <- if(setup_pending?, do: Enum.take(roles, 1), else: roles) do
      {:ok, %Run{}} = start_role_run(task, role, fresh: true)
    end

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
  defp asked(%Issue{skipped_steps: skipped}, %Round{record_demo: true}), do: if(:demo in skipped, do: [], else: [:demo])
  defp asked(%Issue{}, _round), do: []

  # Round 1 is always walked whole, and a round git cannot tell apart, or one with no QA run to mark, is QA's.
  defp unseen(%Task{} = task) do
    with %{number: number} = change <- round_change(task),
         %Project{qa_skip_paths: [_glob | _rest] = globs} <- Repo.get(Project, task.project_id),
         {:ok, [_path | _rest] = paths} <- Git.list_round_paths(task, change),
         true <- Enum.all?(paths, fn path -> Enum.any?(globs, &matches_glob?(path, &1)) end),
         [_run | _rest] <- qa_runs(task) do
      %{number: number, paths: paths}
    else
      _seen -> nil
    end
  end

  defp skip_qa(%Task{} = task, number, paths) do
    {named, more} = Enum.split(paths, @named)
    files = Enum.join(named, ", ") <> if(more == [], do: "", else: " and #{length(more)} more")
    line = "Round #{number} changed only files nobody sees in the app (#{files}), so QA did not run."

    {:ok, _saved} = Pipeline.save_report(task, :qa, line)

    for %Run{} = run <- qa_runs(task) do
      {:ok, _skipped} = run |> Run.changeset(%{stage_outcome: :skipped}) |> Repo.update()
      Pipeline.append_run_events(run.id, nil, ["[qa] " <> line])
    end
  end

  defp qa_runs(%Task{} = task) do
    Repo.all(from r in Run, join: role in assoc(r, :role), where: r.task_id == ^task.id and role.stage == :qa)
  end
end
