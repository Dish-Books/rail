defmodule Rail.Issues.Workers.AdvanceTrackerStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Users

  # DataCase verifies Mimic, not Req.Test: without this a move that never went out would pass.
  setup {Req.Test, :verify_on_exit!}

  describe "a Linear issue" do
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

      {:ok, owner} = Users.register_oauth_user(%{github_id: "gh_owner", login: "owner", email: "owner@example.com"})

      {:ok, issue} =
        Issues.create_issue(system_scope(), project, %{description: "Advance Issue", owner_user_id: owner.id})

      {:ok, task} = Pipeline.create_task(issue, :plan)

      # In Review comes before In Progress, so the started pick has to go by position,
      # not by the order sent.
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

    test "product moves a ticket still in Triage, where Rail opens them, to In Progress", %{
      issue: issue,
      nodes: nodes,
      states: states
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_triage"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"input" => %{"stateId" => "st_in_progress"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "product moves a Backlog ticket to In Progress", %{issue: issue, nodes: nodes, states: states} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"input" => %{"stateId" => "st_in_progress"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "design moves a Triage ticket to In Progress", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :plan})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_triage"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"input" => %{"stateId" => "st_in_progress"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "architect moves a Backlog ticket to the team's first started state", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :plan})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"id" => "lin_advance_1", "input" => %{"stateId" => "st_in_progress"}} =
                 Jason.decode!(body)["variables"]

        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "Plan moves a Todo ticket to In Progress", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      for stage <- [:plan] do
        {:ok, _task} = Pipeline.update_task(task, %{stage: stage})

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

        assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
      end
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

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
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

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
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

      assert :ok = perform_job(AdvanceTrackerState, args)
    end

    # The stage entered mid-run was refused a job of its own, because this one was executing.
    test "a job whose task moves on while it writes runs again for the new stage", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_todo"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, _task} = Pipeline.update_task(task, %{stage: :review})
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert {:snooze, 1} = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "a job that had nothing to move still runs again when its task moves on meanwhile", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      {:ok, task} = Pipeline.update_task(task, %{stage: :plan})

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_in_progress"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      assert {:snooze, 1} = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    # A merge of main from Review re-enters the engineer stage.
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

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    # Product approval hands on a ticket that starting the task already moved to In Progress.
    test "design leaves an In Progress ticket there rather than moving it back to Todo", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :plan})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_in_progress"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "starting at Plan leaves an In Review ticket alone", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      for stage <- [:plan] do
        {:ok, _task} = Pipeline.update_task(task, %{stage: stage})

        Req.Test.expect(Rail.Linear, fn conn ->
          Req.Test.json(conn, %{
            "data" => %{"issue" => %{"state" => states["st_in_review"], "team" => %{"states" => %{"nodes" => nodes}}}}
          })
        end)

        assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
      end
    end

    test "never reopens a ticket that is Done or Canceled", %{issue: issue, task: task, nodes: nodes, states: states} do
      for finished <- ["st_done", "st_canceled"],
          stage <- [:plan, :engineer, :review, :merged] do
        {:ok, _task} = Pipeline.update_task(task, %{stage: stage})

        Req.Test.expect(Rail.Linear, fn conn ->
          Req.Test.json(conn, %{
            "data" => %{"issue" => %{"state" => states[finished], "team" => %{"states" => %{"nodes" => nodes}}}}
          })
        end)

        assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
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

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "a project that never stored its team's states still moves the ticket", %{
      project: project,
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      project |> Ecto.Changeset.change(linear_state_ids: %{}) |> Repo.update!()
      {:ok, _task} = Pipeline.update_task(task, %{stage: :plan})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_backlog"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"input" => %{"stateId" => "st_in_progress"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "an issue nobody has claimed leaves Linear untouched", %{issue: issue, task: task} do
      issue |> Ecto.Changeset.change(owner_user_id: nil) |> Repo.update!()
      {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

      # No Linear mock is queued, so a request would raise.
      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "a split parent at Merged moves its ticket to the first completed state", %{
      issue: issue,
      task: task,
      nodes: nodes,
      states: states
    } do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :merged})
      nodes = [%{"id" => "st_shipped", "name" => "Shipped", "type" => "completed", "position" => 1.0} | nodes]

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"issue" => %{"state" => states["st_in_review"], "team" => %{"states" => %{"nodes" => nodes}}}}
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"input" => %{"stateId" => "st_done"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "a task at a stage the ticket does not follow leaves Linear untouched", %{issue: issue, task: task} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :split})

      # No Linear mock is queued, so a request would raise.
      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "an issue whose task was cleaned up leaves Linear untouched", %{issue: issue, task: task} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :review, cleaned_up_at: DateTime.utc_now()})

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
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

      assert {:error, {:linear_mutation_failed, "issueUpdate"}} = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
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
               perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "fails the job with Linear's error when the ticket cannot be read", %{issue: issue, task: task} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :plan})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"errors" => [%{"message" => "Entity not found"}]})
      end)

      assert {:error, {:linear_graphql_error, [%{"message" => "Entity not found"}]}} =
               perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "an issue that is gone needs no move", %{issue: issue} do
      Repo.delete!(issue)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end
  end

  describe "a GitHub issue" do
    setup %{github_project: project} do
      {:ok, owner} = Users.register_oauth_user(%{github_id: "gh_adv_owner", login: "adv-owner", email: "adv@example.com"})
      issue = github_issue(project, %{number: 9, state: :triage, owner_user_id: owner.id})
      {:ok, task} = Pipeline.create_task(issue, :plan)

      %{issue: issue, task: task}
    end

    test "Plan moves a Triage issue to in progress", %{issue: issue} do
      live =
        github_issue_json(%{"number" => 9, "labels" => [%{"name" => "rail:triage"}, %{"name" => "rail:high"}]})

      Req.Test.expect(Client, 4, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/9"} ->
            Req.Test.json(conn, live)

          {"POST", "/repos/example/test-gh/issues/9/labels"} ->
            assert %{"labels" => ["rail:in-progress"]} == Jason.decode!(body)
            Req.Test.json(conn, [])

          {"DELETE", "/repos/example/test-gh/issues/9/labels/rail%3Atriage"} ->
            Req.Test.json(conn, [])
        end
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "review moves an in progress issue to in review", %{issue: issue, task: task} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :review})
      live = github_issue_json(%{"number" => 9, "labels" => [%{"name" => "rail:in-progress"}]})

      Req.Test.expect(Client, 4, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
          {"GET", "/repos/example/test-gh/issues/9"} -> Req.Test.json(conn, live)
          {"POST", "/repos/example/test-gh/issues/9/labels"} -> Req.Test.json(conn, [])
          {"DELETE", "/repos/example/test-gh/issues/9/labels/rail%3Ain-progress"} -> Req.Test.json(conn, [])
        end
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "Merged closes an issue the pull request's merge left open", %{issue: issue, task: task} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :merged})
      live = github_issue_json(%{"number" => 9, "labels" => [%{"name" => "rail:in-review"}]})

      Req.Test.expect(Client, 3, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/9"} ->
            Req.Test.json(conn, live)

          {"PATCH", "/repos/example/test-gh/issues/9"} ->
            assert %{"state" => "closed", "state_reason" => "completed"} == Jason.decode!(body)
            Req.Test.json(conn, Map.put(live, "state", "closed"))
        end
      end)

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "never moves an issue back, nor reopens a closed one", %{issue: issue, task: task} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

      for live <- [
            github_issue_json(%{"number" => 9, "labels" => [%{"name" => "rail:in-review"}]}),
            github_issue_json(%{"number" => 9, "state" => "closed", "state_reason" => "completed"})
          ] do
        Req.Test.expect(Client, 2, fn conn ->
          case conn.request_path do
            "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "ghs_token"})
            "/repos/example/test-gh/issues/9" -> Req.Test.json(conn, live)
          end
        end)

        assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
      end
    end

    test "runs again when its task moves on while it writes", %{issue: issue, task: task} do
      Req.Test.expect(Client, 4, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/9"} ->
            Req.Test.json(conn, github_issue_json(%{"number" => 9, "labels" => [%{"name" => "rail:todo"}]}))

          {"POST", "/repos/example/test-gh/issues/9/labels"} ->
            {:ok, _task} = Pipeline.update_task(task, %{stage: :review})
            Req.Test.json(conn, [])

          {"DELETE", "/repos/example/test-gh/issues/9/labels/rail%3Atodo"} ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert {:error, {:github_api_error, 500, _body}} = perform_job(AdvanceTrackerState, %{issue_id: issue.id})

      Req.Test.expect(Client, 3, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/9"} ->
            Req.Test.json(conn, github_issue_json(%{"number" => 9}))

          {"POST", "/repos/example/test-gh/issues/9/labels"} ->
            {:ok, _task} = Pipeline.update_task(Repo.reload!(task), %{stage: :merged})
            Req.Test.json(conn, [])
        end
      end)

      assert {:snooze, 1} = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    end

    test "an unowned issue, or one that is gone, stays where it is", %{issue: issue} do
      {:ok, unowned} = Issues.update_issue(issue, %{owner_user_id: nil})
      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: unowned.id})

      Repo.delete!(Repo.preload(unowned, :task).task)
      Repo.delete!(unowned)
      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: unowned.id})
    end
  end
end
