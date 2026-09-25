defmodule Rail.Issues.Workers.AdvanceLinearStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.AdvanceLinearState
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

    # Ready for Dev is listed ahead of Todo so the pick has to go by position, not order.
    states = [
      %{"id" => "st_triage", "name" => "Triage", "type" => "triage", "position" => 0.0},
      %{"id" => "st_backlog", "name" => "Backlog", "type" => "backlog", "position" => 0.0},
      %{"id" => "st_ready", "name" => "Ready for Dev", "type" => "unstarted", "position" => 1.0},
      %{"id" => "st_todo", "name" => "Todo", "type" => "unstarted", "position" => 0.0},
      %{"id" => "st_in_progress", "name" => "In Progress", "type" => "started", "position" => 0.0},
      %{"id" => "st_in_review", "name" => "In Review", "type" => "started", "position" => 1.0},
      %{"id" => "st_done", "name" => "Done", "type" => "completed", "position" => 0.0},
      %{"id" => "st_canceled", "name" => "Canceled", "type" => "canceled", "position" => 1.0}
    ]

    %{project: project, issue: issue, states: Map.new(states, &{&1["id"], &1})}
  end

  test "todo moves a backlog ticket to the team's first unstarted state", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"id" => "lin_advance_1", "input" => %{"stateId" => "st_todo"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end

  test "todo moves a ticket still in Triage, where Rail opens them, to Todo", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_triage"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_todo"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end

  # Design and architect enter after product approval has already moved it there.
  test "todo leaves a ticket already at Todo alone", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end

  test "in_progress moves a Todo ticket to In Progress", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_in_progress"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "in_progress"})
  end

  test "in_review moves an In Progress ticket to In Review", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "state" => states["st_in_progress"],
            "team" => %{"states" => %{"nodes" => Map.values(states)}}
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_in_review"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "in_review"})
  end

  # A send-back from review or QA re-enters the engineer stage.
  test "in_progress leaves an In Review ticket at In Review", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_in_review"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "in_progress"})
  end

  test "todo leaves a ticket someone already moved to In Progress alone", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "state" => states["st_in_progress"],
            "team" => %{"states" => %{"nodes" => Map.values(states)}}
          }
        }
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end

  test "never reopens a ticket that is Done or Canceled", %{issue: issue, states: states} do
    for finished <- ["st_done", "st_canceled"], target <- ["todo", "in_progress", "in_review"] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issue" => %{"state" => states[finished], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
          }
        })
      end)

      assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: target})
    end
  end

  test "in_review on a team with no In Review state leaves the ticket where it is", %{
    issue: issue,
    states: states
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "state" => states["st_in_progress"],
            "team" => %{"states" => %{"nodes" => states |> Map.delete("st_in_review") |> Map.values()}}
          }
        }
      })
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "in_review"})
  end

  test "a project that never stored its team's states still moves the ticket", %{
    project: project,
    issue: issue,
    states: states
  } do
    project |> Ecto.Changeset.change(linear_state_ids: %{}) |> Repo.update!()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"stateId" => "st_todo"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end

  test "fails the job when Linear does not take the update", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "in_progress"})
  end

  test "fails the job with Linear's error when the update does not go through", %{issue: issue, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => Map.values(states)}}}
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    assert {:error, {:linear_api_error, 400, %{"error" => "bad request"}}} =
             perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "in_progress"})
  end

  test "fails the job with Linear's error when the ticket cannot be read", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "Entity not found"}]})
    end)

    assert {:error, {:linear_graphql_error, [%{"message" => "Entity not found"}]}} =
             perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end

  test "an issue that is gone needs no move", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(AdvanceLinearState, %{issue_id: issue.id, state: "todo"})
  end
end
