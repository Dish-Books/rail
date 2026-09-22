defmodule Rail.Pipeline.Actions.RecordDemoTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
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
        name: "Demo Project",
        github_repo: "org/demo",
        github_installation_id: 47_091,
        linear_team_key: "DMO",
        default_branch: "main",
        clone_path: "/tmp/repos/demo"
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :demo,
        name: "demo role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the demo agent."
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_dmo",
        identifier: "DMO-1",
        title: "Demo",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :demo,
          worktree_name: "dmo-1",
          worktree_path: create_temp_git_repo(),
          scratch_path: Path.join(System.tmp_dir!(), "demo_#{System.unique_integer([:positive])}")
        },
        project.id
      )
      |> Repo.insert!()

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, role: role}
  end

  test "records a demo the stage was entered without", %{task: task} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{status: :running}} = Pipeline.record_demo(system_scope(), task)
  end

  test "records one already recorded again, as a fresh take", %{task: task, role: role} do
    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_demo",
        started_at: DateTime.utc_now()
      })

    File.mkdir_p!(Path.join(task.scratch_path, "demo"))
    File.write!(Path.join([task.scratch_path, "demo", "demo.webm"]), "video")
    {:ok, task} = Pipeline.update_task(task, %{demo_skipped_at: DateTime.utc_now()})

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Record the walkthrough again, as a fresh take"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running, stage_outcome: :in_progress}} = Pipeline.record_demo(system_scope(), task)
    assert %Task{demo_skipped_at: nil} = Repo.reload!(task)
  end

  test "settles a demo as not needed, which is the demo done", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", "/repos/org/demo/pulls/7"} -> Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7"})
        {"POST", "/graphql"} -> Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{id: run_id, status: :finished, stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
    assert %Task{demo_skipped_at: %DateTime{}, pr_is_draft: false} = Repo.reload!(task)
    assert [%RunEvent{run_id: ^run_id, line: "[human] No demo is needed for this change."}] = Repo.all(RunEvent)
  end

  test "settling a demo that already ran keeps its run", %{task: task, role: role} do
    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        error: "The browser painted no frames, so there is nothing to watch.",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Run{id: ^run_id, stage_outcome: :done, error: nil}} = Pipeline.skip_demo(system_scope(), task)
  end

  test "neither is offered anywhere but the demo stage, or while something runs", %{task: task, role: role} do
    {:ok, at_qa} = Pipeline.update_task(task, %{stage: :qa})
    assert {:error, {:invalid_stage, :qa}} = Pipeline.record_demo(system_scope(), at_qa)
    assert {:error, {:invalid_stage, :qa}} = Pipeline.skip_demo(system_scope(), at_qa)

    {:ok, _task} = Pipeline.update_task(at_qa, %{stage: :demo})

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    assert {:error, :stage_running} = Pipeline.record_demo(system_scope(), task)
    assert {:error, :stage_running} = Pipeline.skip_demo(system_scope(), task)
  end
end
