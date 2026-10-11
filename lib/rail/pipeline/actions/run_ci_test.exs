defmodule Rail.Pipeline.Actions.RunCiTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Run CI Project",
        github_repo: "org/run-ci",
        github_installation_id: 47_041,
        key: "RCI",
        default_branch: "main",
        clone_path: "/tmp/repos/run-ci",
        ci_command: "mise run ci",
        ci_timeout_minutes: 45
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
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

    %{project: project, role: role, run: run, worktree_path: worktree_path}
  end

  # A person asking for CI is saying the work is ready, as a commit from them does.
  test "runs CI again with the count of failures started over, and review to follow a pass", %{run: run} do
    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", opts ->
      assert opts[:timeout_ms] == to_timeout(minute: 45)
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, %Run{status: :running, ci_failure_streak: 0, review_on_ci_pass: true, error: nil}} =
             Pipeline.run_ci(system_scope(), run)
  end

  # The engineer role holds 1 CPU; CI holds the project's number, read afresh at each start.
  test "CI holds the project's CPUs, not its role's, and the next CI holds a raised number", %{
    project: project,
    run: %{id: run_id} = run
  } do
    stub(Rail, :local_cpus, fn -> 8 end)
    {:ok, project} = Projects.update_project(system_scope(), project, %{ci_reserved_cpus: 4})

    assert {:ok, %Run{status: :running}} = Pipeline.run_ci(system_scope(), run)
    assert %OsProcess{status: :running, reserved_cpus: 4} = first = Repo.get_by!(OsProcess, run_id: run_id)

    {:ok, %Project{ci_reserved_cpus: 6}} = Projects.update_project(system_scope(), project, %{ci_reserved_cpus: 6})
    {:ok, _stopped} = Tools.stop_os_process(system_scope(), first, grace_period: 50)
    {:ok, run} = Pipeline.update_run(run, %{status: :finished})

    assert {:ok, %Run{status: :running}} = Pipeline.run_ci(system_scope(), run)

    assert [%OsProcess{status: :finished, reserved_cpus: 4}, %OsProcess{status: :running, reserved_cpus: 6}] =
             Repo.all(from p in OsProcess, where: p.run_id == ^run_id, order_by: [asc: p.inserted_at, asc: p.id])
  end

  # Nothing reads the project again once the row is written, so a CI in line keeps
  # the number it was queued with, and another project's CI keeps its own.
  test "a CI waiting in line keeps its reservation when the project's is raised", %{
    project: project,
    role: role,
    run: %{id: run_id} = run
  } do
    stub(Rail, :local_cpus, fn -> 8 end)
    {:ok, project} = Projects.update_project(system_scope(), project, %{ci_reserved_cpus: 4})

    {:ok, other_run} =
      Pipeline.create_run(%{task_id: run.task_id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    blocker =
      Repo.insert!(%OsProcess{
        run_id: other_run.id,
        task_id: other_run.task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 8
      })

    assert {:ok, %Run{status: :waiting_for_resources}} = Pipeline.run_ci(system_scope(), run)

    other_project =
      %Project{}
      |> Project.changeset(%{
        name: "Other CI Project",
        github_repo: "org/other-ci",
        github_installation_id: 47_042,
        key: "OCI",
        default_branch: "main",
        clone_path: "/tmp/repos/other-ci",
        ci_command: "mix test",
        ci_reserved_cpus: 2
      })
      |> Repo.insert!()

    {:ok, other_role} =
      Roles.create_role(system_scope(), other_project, %{
        cli: :claude,
        stage: :engineer,
        name: "engineer role",
        model: "claude-opus-5-5",
        system_prompt: "You are the engineer."
      })

    other_issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: other_project.id,
        external_id: "lin_other_ci",
        identifier: "OCI-1",
        title: "Other CI",
        state: :backlog
      })
      |> Repo.insert!()

    other_task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: other_issue.id,
          stage: :engineer,
          worktree_name: "oci-1",
          worktree_path: create_temp_git_repo(),
          scratch_path: Path.join(System.tmp_dir!(), "run_ci_#{System.unique_integer([:positive])}")
        },
        other_project.id
      )
      |> Repo.insert!()

    {:ok, %{id: other_ci_run_id} = other_ci_run} =
      Pipeline.create_run(%{
        task_id: other_task.id,
        role_id: other_role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Run{status: :waiting_for_resources}} = Pipeline.run_ci(system_scope(), other_ci_run)

    {:ok, %Project{ci_reserved_cpus: 6}} = Projects.update_project(system_scope(), project, %{ci_reserved_cpus: 6})
    {:ok, _stopped} = Tools.stop_os_process(system_scope(), blocker, grace_period: 50)

    assert %OsProcess{status: :running, reserved_cpus: 4} = Repo.get_by!(OsProcess, run_id: run_id)
    assert %OsProcess{status: :running, reserved_cpus: 2} = Repo.get_by!(OsProcess, run_id: other_ci_run_id)

    assert [
             "[rail] CI needs 4 CPUs, and every CPU on this machine is reserved. " <>
               "It is 1st in line and starts on its own as soon as enough is free."
           ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
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
    assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
  end
end
