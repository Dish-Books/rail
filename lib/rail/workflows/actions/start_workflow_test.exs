defmodule Rail.Workflows.Actions.StartWorkflowTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition
  alias Rail.Workflows.Workers.StartWorkflowTask

  setup %{project: project} do
    workflow =
      %Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      }
      |> Repo.insert!()
      |> Repo.preload(:project)

    Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")

    %{workflow: workflow}
  end

  test "a due workflow opens one unassigned ticket on its own project's team and queues its task's start", %{
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

    assert {:ok,
            %Issue{
              id: issue_id,
              identifier: "TST-84",
              project_id: ^project_id,
              workflow_id: ^workflow_id,
              owner_user_id: nil,
              description: "Update the dependencies."
            }} = Workflows.start_workflow(workflow)

    assert_enqueued(worker: StartWorkflowTask, args: %{issue_id: issue_id})

    assert %Workflow{next_run_at: ~U[2026-10-19 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
    assert_receive {:workflows_changed, ^project_id}
  end

  test "a workflow on a GitHub project opens its issue in that repository", %{github_project: project} do
    workflow =
      %Workflow{
        project_id: project.id,
        path: ".rail/workflows/sweep.yaml",
        definition: %WorkflowDefinition{name: "Sweep", schedule: "0 9 * * 1", instructions: "Update the dependencies."},
        next_run_at: ~U[2026-10-12 09:00:00Z]
      }
      |> Repo.insert!()
      |> Repo.preload(:project)

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

    assert {:ok, %Issue{id: issue_id, tracker: :github, identifier: "tgh#42", owner_user_id: nil}} =
             Workflows.start_workflow(workflow)

    assert_enqueued(worker: StartWorkflowTask, args: %{issue_id: issue_id})
  end

  test "a workflow whose last issue is unfinished opens nothing and still moves its due time on", %{
    workflow: %{id: workflow_id} = workflow
  } do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-78", "identifier" => "TST-78", "title" => "Dependency updates 2026-10-12"}
          }
        }
      })
    end)

    {:ok, %Issue{id: unfinished_id}} = Workflows.start_workflow(workflow)

    stub(DateTime, :utc_now, fn -> ~U[2026-10-19 09:01:00.000000Z] end)

    assert {:error, {:unfinished, %Issue{id: ^unfinished_id}}} = Workflows.start_workflow(workflow)
    assert %Workflow{next_run_at: ~U[2026-10-26 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
    assert [_one] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
    assert [%Oban.Job{args: %{"issue_id" => ^unfinished_id}}] = all_enqueued(worker: StartWorkflowTask)
  end

  test "a finished last issue lets the next one open", %{workflow: %{id: workflow_id} = workflow} do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-78", "identifier" => "TST-78", "title" => "Dependency updates 2026-10-12"}
          }
        }
      })
    end)

    {:ok, issue} = Workflows.start_workflow(workflow)
    issue |> Issue.tracker_changeset(%{state: :done}) |> Repo.update!()

    stub(DateTime, :utc_now, fn -> ~U[2026-10-19 09:00:10.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-79", "identifier" => "TST-79", "title" => "Dependency updates 2026-10-19"}
          }
        }
      })
    end)

    assert {:ok, %Issue{id: next_id, identifier: "TST-79", title: "Dependency updates 2026-10-19"}} =
             Workflows.start_workflow(workflow)

    assert_enqueued(worker: StartWorkflowTask, args: %{issue_id: next_id})

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

    %Workflow{id: workflow_id} =
      workflow =
      %Workflow{
        project_id: inactive.id,
        path: ".rail/workflows/changelog.yml",
        definition: %WorkflowDefinition{name: "Changelog", schedule: "0 9 * * 1", instructions: "Draft the changelog."},
        next_run_at: ~U[2026-10-12 09:00:00Z]
      }
      |> Repo.insert!()
      |> Repo.preload(:project)

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
    workflow =
      %Workflow{project_id: project.id, path: ".rail/workflows/broken.yml"}
      |> Repo.insert!()
      |> Repo.preload(:project)

    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    assert {:error, :invalid} = Workflows.start_workflow(workflow)
  end

  test "a start racing a Run now from another process opens one issue between them", %{
    workflow: %{id: workflow_id} = workflow
  } do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-90", "identifier" => "TST-90", "title" => "Dependency updates 2026-10-12"}
          }
        }
      })
    end)

    scheduled = Elixir.Task.async(fn -> Workflows.start_workflow(workflow) end)
    now = Elixir.Task.async(fn -> Workflows.run_workflow_now(system_scope(), workflow) end)

    assert [{:ok, %Issue{id: issue_id}}, {:error, {:unfinished, %Issue{id: issue_id}}}] =
             Enum.sort_by(Elixir.Task.await_many([scheduled, now]), &elem(&1, 0), :desc)

    assert [%Issue{id: ^issue_id}] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
    assert [%Oban.Job{args: %{"issue_id" => ^issue_id}}] = all_enqueued(worker: StartWorkflowTask)
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
    refute_enqueued(worker: StartWorkflowTask)
    assert %Workflow{next_run_at: ~U[2026-10-19 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
  end
end
