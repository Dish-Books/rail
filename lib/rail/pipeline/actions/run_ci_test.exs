defmodule Rail.Pipeline.Actions.RunCiTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Run CI Project",
        github_repo: "org/run-ci",
        github_installation_id: 47_041,
        linear_team_key: "RCI",
        default_branch: "main",
        clone_path: "/tmp/repos/run-ci",
        ci_command: "mise run ci",
        ci_timeout_minutes: 45
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-opus-5-5",
        system_prompt: "You are the engineer."
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_run_ci",
        identifier: "RCI-1",
        title: "Run CI",
        state: :backlog
      })
      |> Repo.insert!()

    worktree_path = create_temp_git_repo()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "rci-1",
          worktree_path: worktree_path,
          scratch_path: Path.join(System.tmp_dir!(), "run_ci_#{System.unique_integer([:positive])}")
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        ci_failure_streak: 3,
        error: "CI failed 3 times in a row",
        started_at: DateTime.utc_now()
      })

    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)

    %{project: project, run: run, worktree_path: worktree_path}
  end

  test "runs CI again with the count of failures started over", %{run: run} do
    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", opts ->
      assert opts[:timeout_ms] == to_timeout(minute: 45)
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, %Run{status: :running, ci_failure_streak: 0, error: nil}} = Pipeline.run_ci(system_scope(), run)
  end

  test "a project without CI has none to run", %{project: project, run: run} do
    project |> Project.changeset(%{ci_command: nil}) |> Repo.update!()

    assert {:error, :no_ci_command} = Pipeline.run_ci(system_scope(), run)
  end

  test "a run that is working is left to it", %{run: run} do
    {:ok, run} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.run_ci(system_scope(), run)
  end

  test "uncommitted work is committed first, not run past", %{run: run, worktree_path: worktree_path} do
    File.write!(Path.join(worktree_path, "loose.ex"), "one\n")

    assert {:error, :uncommitted_changes} = Pipeline.run_ci(system_scope(), run)
  end

  test "a CI that cannot start says why", %{run: run} do
    expect(Tools, :start_command_process, fn _run, :ci, _command, _opts -> {:error, {:bad_cwd, "/gone"}} end)

    assert {:error, "Could not start CI: {:bad_cwd, \"/gone\"}"} = Pipeline.run_ci(system_scope(), run)
  end
end
