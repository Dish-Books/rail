defmodule Rail.Workflows.Actions.StartWorkflowTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow

  setup %{project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/dependency-updates.yml" => workflow_yaml()})
    Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")

    %{workflow: workflow}
  end

  test "a due workflow opens one unassigned ticket on its own project's team and starts its task at Plan", %{
    project: %{id: project_id},
    workflow: %{id: workflow_id} = workflow
  } do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      input = Jason.decode!(body)["variables"]["input"]

      assert %{
               "teamId" => "lin_team_id",
               "title" => "Dependency updates 2026-10-12",
               "description" => "Update the dependencies.",
               "stateId" => "st_triage"
             } = input

      refute Map.has_key?(input, "assigneeId")

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_wf_1",
              "identifier" => "TST-84",
              "title" => "Dependency updates 2026-10-12",
              "description" => "Update the dependencies."
            }
          }
        }
      })
    end)

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok,
            %Issue{
              id: issue_id,
              identifier: "TST-84",
              project_id: ^project_id,
              workflow_id: ^workflow_id,
              owner_user_id: nil,
              description: "Update the dependencies."
            }} = Workflows.start_workflow(workflow)

    assert [%Task{stage: :plan, runs: [%Run{}]}] =
             Repo.all(from(t in Task, where: t.issue_id == ^issue_id, preload: :runs))

    assert %Workflow{next_run_at: ~U[2026-10-19 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
    assert_receive {:workflows_changed, ^project_id}
  end

  test "a workflow on a GitHub project opens its issue in that repository", %{github_project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/sweep.yaml" => workflow_yaml(%{"name" => "Sweep"})})
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    Req.Test.expect(Client, 2, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          sent = Jason.decode!(body)
          assert %{"title" => "Sweep 2026-10-12", "body" => "Update the dependencies."} = sent
          refute Map.has_key?(sent, "assignees")
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(github_issue_json(%{"title" => "Sweep 2026-10-12"}))
      end
    end)

    expect(Pipeline, :start_task, fn %Issue{}, :plan -> {:ok, %Task{}} end)

    assert {:ok, %Issue{tracker: :github, identifier: "tgh#42", owner_user_id: nil}} = Workflows.start_workflow(workflow)
  end

  test "a workflow whose last issue is unfinished opens nothing and still moves its due time on", %{
    workflow: %{id: workflow_id} = workflow
  } do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)
    expect_linear_issue("TST-78")
    stub(Pipeline, :start_task, fn %Issue{}, :plan -> {:ok, %Task{}} end)
    {:ok, %Issue{id: unfinished_id}} = Workflows.start_workflow(workflow)

    stub(DateTime, :utc_now, fn -> ~U[2026-10-19 09:01:00.000000Z] end)

    assert {:error, {:unfinished, %Issue{id: ^unfinished_id}}} = Workflows.start_workflow(workflow)
    assert %Workflow{next_run_at: ~U[2026-10-26 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
    assert [_one] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
  end

  test "a finished last issue lets the next one open", %{workflow: %{id: workflow_id} = workflow} do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)
    expect_linear_issue("TST-78")
    stub(Pipeline, :start_task, fn %Issue{}, :plan -> {:ok, %Task{}} end)
    {:ok, issue} = Workflows.start_workflow(workflow)
    issue |> Issue.tracker_changeset(%{state: :done}) |> Repo.update!()

    stub(DateTime, :utc_now, fn -> ~U[2026-10-19 09:00:10.000000Z] end)
    expect_linear_issue("TST-79")

    assert {:ok, %Issue{identifier: "TST-79", title: "Dependency updates 2026-10-19"}} =
             Workflows.start_workflow(workflow)

    assert [_first, _second] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
  end

  test "a paused workflow opens nothing and still moves its due time on", %{
    project: %{id: project_id},
    workflow: %{id: workflow_id} = workflow
  } do
    {:ok, paused} = Workflows.set_workflow_paused(system_scope(), workflow, true)
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    # No tracker request is expected, so one would raise.
    assert {:error, :paused} = Workflows.start_workflow(paused)
    assert %Workflow{next_run_at: ~U[2026-10-19 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
    assert [] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
    assert_receive {:workflows_changed, ^project_id}
  end

  test "a workflow on an inactive project opens nothing and still moves its due time on" do
    {:ok, inactive} =
      Projects.create_project(system_scope(), %{
        name: "Inactive workflows",
        github_repo: "example/inactive-workflows",
        github_installation_id: 1,
        default_branch: "main",
        key: "INW",
        clone_path: "/tmp/repos/inactive-workflows",
        active: false
      })

    [%{id: workflow_id} = workflow] =
      sync_workflow_files(inactive, %{".rail/workflows/changelog.yml" => workflow_yaml(%{"name" => "Changelog"})})

    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    assert {:error, :project_inactive} = Workflows.start_workflow(workflow)
    assert %Workflow{next_run_at: ~U[2026-10-19 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
  end

  test "a workflow not yet due opens nothing and keeps its due time", %{workflow: %{id: workflow_id} = workflow} do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:59:59.000000Z] end)

    assert {:error, :not_due} = Workflows.start_workflow(workflow)
    assert %Workflow{next_run_at: ~U[2026-10-12 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
  end

  test "an invalid workflow opens nothing", %{project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/broken.yml" => "name: ["})
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    assert {:error, :invalid} = Workflows.start_workflow(workflow)
  end

  test "a start racing a Run now from another process opens one issue between them", %{
    workflow: %{id: workflow_id} = workflow
  } do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)
    expect_linear_issue("TST-90")
    stub(Pipeline, :start_task, fn %Issue{}, :plan -> {:ok, %Task{}} end)

    scheduled = Elixir.Task.async(fn -> Workflows.start_workflow(workflow) end)
    now = Elixir.Task.async(fn -> Workflows.run_workflow_now(system_scope(), workflow) end)

    assert [{:ok, %Issue{id: issue_id}}, {:error, {:unfinished, %Issue{id: issue_id}}}] =
             Enum.sort_by(Elixir.Task.await_many([scheduled, now]), &elem(&1, 0), :desc)

    assert [%Issue{id: ^issue_id}] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
  end

  test "a tracker error opens nothing and leaves the start to the next due time", %{
    workflow: %{id: workflow_id} = workflow
  } do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    assert {:error, {:linear_api_error, 500, _body}} = Workflows.start_workflow(workflow)
    assert [] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
    assert %Workflow{next_run_at: ~U[2026-10-19 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
  end

  test "a task that will not start leaves the opened issue and says so in the log", %{workflow: workflow} do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)
    expect_linear_issue("TST-91")
    expect(Pipeline, :start_task, fn %Issue{}, :plan -> {:error, :dispatch_disabled} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %Issue{identifier: "TST-91"}} = Workflows.start_workflow(workflow)
      end)

    assert log =~ "Could not start TST-91, opened by a workflow: :dispatch_disabled"
  end
end
