defmodule Rail.Pipeline.Actions.GetCiStatusTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
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
        name: "CI Status Project",
        github_repo: "org/ci-status",
        github_installation_id: 47_051,
        linear_team_key: "CIS",
        default_branch: "main",
        clone_path: "/tmp/repos/ci-status",
        ci_command: "mise run ci"
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
        external_id: "lin_cis",
        identifier: "CIS-1",
        title: "CI",
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
          worktree_name: "cis-1",
          worktree_path: worktree_path,
          scratch_path: "/tmp/cis"
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        ci_failure_streak: 1,
        started_at: DateTime.utc_now()
      })

    ci = fn attrs ->
      %OsProcess{}
      |> OsProcess.changeset(
        Map.merge(
          %{
            run_id: run.id,
            task_id: task.id,
            kind: :ci,
            stream_path: "/tmp/#{System.unique_integer([:positive])}.log",
            status: :finished,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    %{project: project, run: run, ci: ci, head_sha: String.trim(git!(worktree_path, ["rev-parse", "HEAD"]))}
  end

  test "a project without CI has no status to give", %{project: project, run: run} do
    project |> Project.changeset(%{ci_command: ""}) |> Repo.update!()

    assert Pipeline.get_ci_status(run) == nil
  end

  test "CI that has not run on this commit is pending", %{run: run} do
    assert %{state: :pending, os_process: nil} = Pipeline.get_ci_status(run)
  end

  test "reads CI running, passed and failed off the latest run of it", %{run: run, ci: ci, head_sha: head_sha} do
    ci.(%{status: :running})
    assert %{state: :running} = Pipeline.get_ci_status(run)

    ci.(%{exit_code: 1, head_sha: head_sha})
    assert %{state: :failed, failures: 1} = Pipeline.get_ci_status(run)

    ci.(%{exit_code: 0, head_sha: head_sha})
    assert %{state: :passed, os_process: %OsProcess{exit_code: 0}} = Pipeline.get_ci_status(run)
  end

  test "a pass for a commit the branch has moved on from is pending again", %{run: run, ci: ci} do
    ci.(%{exit_code: 0, head_sha: "0000000000000000000000000000000000000000"})

    assert %{state: :pending} = Pipeline.get_ci_status(run)
  end
end
