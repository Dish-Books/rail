defmodule Rail.Pipeline.Utils.SetupRunFinished do
  @moduledoc """
  Where a finished worktree setup leaves its run: carrying on with whatever was
  waiting for it, or failed on what the script said.
  """

  import Rail.Pipeline.Utils.FailPlanWithoutApp
  import Rail.Pipeline.Utils.StartChecks

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc "Finishes `run` after its worktree setup script exited."
  def setup_run_finished(%Run{exit_code: 0, task: %Task{} = task, role: %Role{} = role} = run, _opts) do
    {:ok, task} = task |> Task.changeset(%{worktree_setup_at: DateTime.utc_now()}) |> Repo.update()
    run = %{run | task: task}

    # Marked set up first, so a save from here on writes it too and the later of the two wins.
    %Task{project: %Project{} = project} = Repo.preload(task, :project)

    case Git.copy_env_file(project, task) do
      :ok ->
        # A message queued on a conversation already under way is drained once this
        # returns; anything else was held up on its way into the stage.
        cond do
          resuming_chat?(run) ->
            run

          # A check's setup at Review held back the others, since they share the worktree.
          task.stage == :review and role.stage in Task.check_stages() ->
            :ok = start_checks(task)
            %{Repo.get!(Run, run.id) | task: task, role: role}

          # The curator works no stage, so it starts here as a stage's agent does.
          role.stage == :curator ->
            {:ok, curator} = Roles.get_role(id: role.id)

            {:ok, %OsProcess{run: started}} =
              Pipeline.start_curator_run(%{Repo.get!(Run, run.id) | task: task, role: curator})

            started

          Task.works_stage?(task, role) ->
            {:ok, %Run{} = entered} = Pipeline.enter_stage(task, Task.current_stage(task))

            entered

          true ->
            run
        end

      # Not set up after all, so Retry runs the script again and copies once the file can be written.
      {:error, message} ->
        {:ok, task} = task |> Task.changeset(%{worktree_setup_at: nil}) |> Repo.update()

        fail(
          %{run | task: task},
          "Rail could not write the project's .env into the worktree (#{message}). Once that is fixed, retry."
        )
    end
  end

  def setup_run_finished(%Run{} = run, _opts) do
    why = run.error || "exit #{run.exit_code}"
    fail(run, "The worktree setup script failed (#{why}). Its output is above; once what it reports is fixed, retry.")
  end

  @doc """
  Finishes a setup that ran beside `run`'s agent, Plan's, against how it exited. A setup that worked marks the
  worktree set up and says so in the run's log, leaving the run as the agent has it. One that failed fails the plan,
  since Plan never designs from the code alone, and the message that carries on starts it again. One that was
  stopped only says so: whoever stopped it stopped the run too.
  """
  def setup_beside_finished(%Run{task: %Task{} = task} = run, 0, _error) do
    {:ok, task} = task |> Task.changeset(%{worktree_setup_at: DateTime.utc_now()}) |> Repo.update()
    %Task{project: %Project{} = project} = Repo.preload(task, :project)

    case Git.copy_env_file(project, task) do
      :ok ->
        beside_said(run, "[rail] The worktree is set up, so the app can run and `browser_connect` opens a browser.")

      {:error, message} ->
        {:ok, _task} = task |> Task.changeset(%{worktree_setup_at: nil}) |> Repo.update()
        _error = fail_plan_without_app(run, "Rail could not write the project's .env into the worktree (#{message}).")
        reloaded(run)
    end
  end

  def setup_beside_finished(%Run{} = run, -1, _error) do
    beside_said(
      run,
      "[rail] The worktree setup was stopped before it finished, so the app cannot run yet. The next turn sets it up again."
    )
  end

  def setup_beside_finished(%Run{} = run, exit_code, error) do
    _error =
      fail_plan_without_app(
        run,
        "The worktree setup script failed (#{error || "exit #{exit_code}"}); its output is above."
      )

    reloaded(run)
  end

  defp beside_said(%Run{} = run, line) do
    Pipeline.append_run_events(run.id, nil, [line])
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
    reloaded(run)
  end

  defp reloaded(%Run{} = run), do: %{Repo.get!(Run, run.id) | task: Repo.get!(Task, run.task_id), role: run.role}

  defp resuming_chat?(%Run{pending_chat: queued}) when queued in [nil, ""], do: false
  defp resuming_chat?(%Run{id: run_id}), do: Tools.list_os_processes(run_id: run_id, kind: :agent) != []

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
