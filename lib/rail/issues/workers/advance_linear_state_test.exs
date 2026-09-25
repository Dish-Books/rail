defmodule Rail.Issues.Workers.AdvanceLinearStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Pipeline
  alias Rail.Repo

  # DataCase verifies Mimic, not Req.Test: without this a move that never went out would pass.
  setup {Req.Test, :verify_on_exit!}

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_advance_1",
              "identifier" => "ADV-1",
              "title" => "Advance Issue",
              "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"}
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Advance Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    # Ready for Dev comes before Todo and In Review before In Progress, so both the
    # unstarted and the started pick have to go by position, not by the order sent.
    nodes = [
      %{"id" => "st_triage", "name" => "Triage", "type" => "triage", "position" => 0.0},
      %{"id" => "st_backlog", "name" => "Backlog", "type" => "backlog", "position" => 0.0},
      %{"id" => "st_ready", "name" => "Ready for Dev", "type" => "unstarted", "position" => 1.0},
      %{"id" => "st_todo", "name" => "Todo", "type" => "unstarted", "position" => 0.0},
      %{"id" => "st_in_review", "name" => "In Review", "type" => "started", "position" => 1.0},
      %{"id" => "st_in_progress", "name" => "In Progress", "type" => "started", "position" => 0.0},
      %{"id" => "st_done", "name" => "Done", "type" => "completed", "position" => 0.0},
      %{"id" => "st_canceled", "name" => "Canceled", "type" => "canceled", "position" => 1.0}
    ]

    %{project: project, issue: issue, task: task, nodes: nodes, states: Map.new(nodes, &{&1["id"], &1})}
  end

  test "design moves a ticket still in Triage, where Rail opens them, to Todo", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :design})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_triage"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_todo"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "architect moves a backlog ticket to the team's first unstarted state", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :architect})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"id" => "lin_advance_1", "input" => %{"stateId" => "st_todo"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  # Design and architect enter after product approval has already moved it there.
  test "design leaves a ticket already at Todo alone", %{issue: issue, task: task, nodes: nodes, states: states} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :design})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "the engineer moves a Todo ticket to In Progress", %{issue: issue, task: task, nodes: nodes, states: states} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_in_progress"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "review moves an In Progress ticket to In Review", %{issue: issue, task: task, nodes: nodes, states: states} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :review})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_in_progress"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_in_review"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  # Two jobs running together must not let the earlier stage's write land last.
  test "a job queued at the engineer stage aims at In Review once the task has moved to review", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})
    {:ok, %Oban.Job{args: args}} = Issues.advance_issue_state(issue)
    {:ok, _task} = Pipeline.update_task(task, %{stage: :review})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_in_review"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, args)
  end

  # A send-back from review or QA re-enters the engineer stage.
  test "the engineer leaves an In Review ticket at In Review", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_in_review"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "design leaves a ticket someone already moved to In Progress alone", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :design})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_in_progress"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "never reopens a ticket that is Done or Canceled", %{issue: issue, task: task, nodes: nodes, states: states} do
    for finished <- ["st_done", "st_canceled"], stage <- [:design, :architect, :engineer, :review, :qa, :demo] do
      {:ok, _task} = Pipeline.update_task(task, %{stage: stage})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states[finished], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
    end
  end

  test "review on a team with no In Review state leaves the ticket where it is", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :review})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "state" => states["st_in_progress"],
            "team" => %{"states" => %{"nodes" => Enum.reject(nodes, &(&1["id"] == "st_in_review"))}}
          }
        }
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "a project that never stored its team's states still moves the ticket", %{
    project: project,
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    project |> Ecto.Changeset.change(linear_state_ids: %{}) |> Repo.update!()
    {:ok, _task} = Pipeline.update_task(task, %{stage: :design})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_todo"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "a task at a stage the ticket does not follow leaves Linear untouched", %{issue: issue} do
    # The task is still at product, and no Linear mock is queued, so a request would raise.
    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "an issue whose task was cleaned up leaves Linear untouched", %{issue: issue, task: task} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :review, cleaned_up_at: DateTime.utc_now()})

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "fails the job when Linear does not take the update", %{issue: issue, task: task, nodes: nodes, states: states} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "fails the job with Linear's error when the update does not go through", %{
    issue: issue,
    task: task,
    nodes: nodes,
    states: states
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => nodes}}}}
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    assert {:error, {:linear_api_error, 400, %{"error" => "bad request"}}} =
             perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "fails the job with Linear's error when the ticket cannot be read", %{issue: issue, task: task} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :design})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "Entity not found"}]})
    end)

    assert {:error, {:linear_graphql_error, [%{"message" => "Entity not found"}]}} =
             perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end

  test "an issue that is gone needs no move", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id})
  end
end
