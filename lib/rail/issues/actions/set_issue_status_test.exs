defmodule Rail.Issues.Actions.SetIssueStatusTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  @in_review %{id: "st_review", name: "In Review", state: :in_review}
  @in_progress %{id: "st_started", name: "In Progress", state: :in_progress}
  @done %{id: "st_done", name: "Done", state: :done}

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_status_1",
        identifier: "STA-1",
        title: "A status to change",
        state: :in_progress,
        state_name: "In Progress",
        external_updated_at: ~U[2026-11-01 09:00:00.000000Z]
      })
      |> Repo.insert!()

    answer = fn conn, state, updated_at, completed_at ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueUpdate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_status_1",
              "identifier" => "STA-1",
              "title" => "A status to change",
              "state" => state,
              "completedAt" => completed_at,
              "updatedAt" => updated_at
            }
          }
        }
      })
    end

    %{issue: issue, answer: answer}
  end

  describe "on Linear" do
    test "In Review goes by its id and as the person, and the row reads it while its state stays In Progress", %{
      issue: %{id: issue_id} = issue,
      answer: answer
    } do
      {:ok, user} =
        Users.register_oauth_user(%{github_id: "gh_status", login: "status_owner", email: "status@example.com"})

      {:ok, user} =
        Users.update_user(Scope.for_system(), user, %{
          linear_access_token: "lin_status_token",
          linear_refresh_token: "lin_status_refresh",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
        })

      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_status_token"]

        assert %{"id" => "lin_status_1", "input" => %{"stateId" => "st_review"} = input} =
                 Jason.decode!(body)["variables"]

        assert map_size(input) == 1
        answer.(conn, %{"name" => "In Review", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:ok,
              %Issue{
                id: ^issue_id,
                state: :in_progress,
                state_name: "In Review",
                external_updated_at: ~U[2026-11-01 10:00:00.000000Z]
              }} = Issues.set_issue_status(Scope.for_user(%{user | admin: true}), issue, @in_review)

      assert %Issue{state: :in_progress, state_name: "In Review"} = Repo.get!(Issue, issue_id)
      assert_received {:issue_changed, ^issue_id}
      refute_enqueued(worker: SyncIssue)
    end

    test "a custom status lands by name, and only that status's write touches the row", %{
      issue: issue,
      answer: answer
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "Waiting on deploy", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:ok, %Issue{state: :in_progress, state_name: "Waiting on deploy", title: "A status to change"}} =
               Issues.set_issue_status(system_scope(), issue, %{
                 id: "st_deploy",
                 name: "Waiting on deploy",
                 state: :in_progress
               })
    end

    test "two picks with the page's copy one behind both reach Linear", %{issue: issue, answer: answer} do
      test = self()

      Req.Test.expect(Rail.Linear, 2, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"input" => %{"stateId" => state_id}} = Jason.decode!(body)["variables"]
        send(test, {:sent, state_id})

        case state_id do
          "st_review" -> answer.(conn, %{"name" => "In Review", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
          "st_started" -> answer.(conn, %{"name" => "In Progress", "type" => "started"}, "2026-11-01T10:00:01.000Z", nil)
        end
      end)

      assert {:ok, %Issue{state_name: "In Review"}} = Issues.set_issue_status(system_scope(), issue, @in_review)
      assert {:ok, %Issue{state_name: "In Progress"}} = Issues.set_issue_status(system_scope(), issue, @in_progress)

      assert_received {:sent, "st_review"}
      assert_received {:sent, "st_started"}
    end

    test "the status the issue already has sends nothing and broadcasts nothing", %{issue: %{id: issue_id} = issue} do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      assert {:ok, %Issue{id: ^issue_id, state_name: "In Progress"}} =
               Issues.set_issue_status(system_scope(), issue, @in_progress)

      refute_received {:issue_changed, ^issue_id}
    end

    test "an issue Linear never named is compared by Rail's label", %{project: project} do
      issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_status_unnamed",
          identifier: "STA-9",
          title: "No name",
          state: :in_progress
        })
        |> Repo.insert!()

      assert {:ok, %Issue{state_name: nil}} = Issues.set_issue_status(system_scope(), issue, @in_progress)
    end

    test "a refusal leaves the row as it was, queues nothing and broadcasts nothing", %{issue: %{id: issue_id} = issue} do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"issueUpdate" => %{"success" => false}}}))

      assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
               Issues.set_issue_status(system_scope(), issue, @done)

      assert %Issue{state: :in_progress, state_name: "In Progress", completed_at: nil} = Repo.get!(Issue, issue_id)
      refute_received {:issue_changed, ^issue_id}
      refute_enqueued(worker: SyncIssue)
      refute_enqueued(worker: IssueFinished)
    end

    test "Linear not answering leaves the row as it was", %{issue: %{id: issue_id} = issue} do
      Req.Test.expect(Rail.Linear, &Plug.Conn.send_resp(&1, 500, "down"))

      assert {:error, {:linear_api_error, 500, _body}} = Issues.set_issue_status(system_scope(), issue, @done)
      assert %Issue{state: :in_progress} = Repo.get!(Issue, issue_id)
    end

    test "a scope without the project is refused before any request", %{issue: issue} do
      assert {:error, :not_found} = Issues.set_issue_status(temp_user_scope(), issue, @done)
    end

    test "a row deleted before the pick gives an error", %{issue: issue} do
      Repo.delete!(issue)

      assert {:error, :not_found} = Issues.set_issue_status(system_scope(), issue, @done)
    end

    test "a row deleted during the call gives an error rather than a crash", %{issue: issue, answer: answer} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Repo.delete!(issue)
        answer.(conn, %{"name" => "In Review", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:error, :not_found} = Issues.set_issue_status(system_scope(), issue, @in_review)
    end

    test "an answer older than the row writes nothing", %{issue: %{id: issue_id} = issue, answer: answer} do
      Req.Test.expect(Rail.Linear, fn conn ->
        # A webhook for a later change lands while the call is out.
        Repo.update!(
          Issue.tracker_changeset(Repo.get!(Issue, issue_id), %{
            state_name: "Blocked",
            external_updated_at: ~U[2026-11-01 11:00:00.000000Z]
          })
        )

        answer.(conn, %{"name" => "In Review", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:ok, %Issue{state_name: "Blocked"}} = Issues.set_issue_status(system_scope(), issue, @in_review)
      assert %Issue{state_name: "Blocked"} = Repo.get!(Issue, issue_id)
    end

    test "a row with no tracker time yet takes the answer", %{issue: issue, answer: answer} do
      issue = issue |> Ecto.Changeset.change(external_updated_at: nil) |> Repo.update!()

      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "In Review", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:ok, %Issue{state_name: "In Review"}} = Issues.set_issue_status(system_scope(), issue, @in_review)
    end

    test "a webhook older than the pick's answer is dropped", %{
      project: project,
      issue: %{id: issue_id} = issue,
      answer: answer
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "In Review", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:ok, %Issue{}} = Issues.set_issue_status(system_scope(), issue, @in_review)

      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      assert :ok =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => "lin_status_1",
                   "teamId" => "lin_team_id",
                   "identifier" => "STA-1",
                   "title" => "A status to change",
                   "state" => %{"name" => "In Progress", "type" => "started"},
                   "updatedAt" => "2026-11-01T09:30:00.000Z"
                 }
               })

      assert %Issue{state_name: "In Review"} = Repo.get!(Issue, issue_id)
    end
  end

  describe "a finish" do
    test "writes Linear's completed time and tells Learnings and the pipeline", %{
      issue: %{id: issue_id} = issue,
      answer: answer
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z", "2026-11-01T10:00:00.000Z")
      end)

      expect(Pipeline, :handle_issue_finished, fn %Issue{id: ^issue_id, state: :done} -> :ok end)

      assert {:ok, %Issue{id: ^issue_id, state: :done, state_name: "Done", completed_at: ~U[2026-11-01 10:00:00Z]}} =
               Issues.set_issue_status(system_scope(), issue, @done)

      assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
    end

    test "moves a split on, reading the child as finished", %{project: project, answer: answer} do
      parent_issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_split_parent",
          identifier: "STA-2",
          title: "Parent",
          state: :in_progress
        })
        |> Repo.insert!()
        |> Repo.preload(:project)

      child_issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_split_child",
          identifier: "STA-3",
          title: "Child",
          state: :in_progress,
          state_name: "In Progress"
        })
        |> Repo.insert!()

      {:ok, %Task{id: parent_id}} = Pipeline.create_task(parent_issue, :split)

      project
      |> build_task(child_issue, %{stage: :engineer, split_position: 1})
      |> Ecto.Changeset.put_change(:parent_task_id, parent_id)
      |> Repo.insert!()

      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z", "2026-11-01T10:00:00.000Z")
      end)

      assert {:ok, %Issue{state: :done}} = Issues.set_issue_status(system_scope(), child_issue, @done)
      assert_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent_id})
    end

    test "a pick on a row a webhook already finished tells nobody again", %{
      project: project,
      issue: %{id: issue_id} = issue,
      answer: answer
    } do
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      # A Mimic count, because Oban's uniqueness would hide a second job.
      expect(Pipeline, :handle_issue_finished, 1, fn %Issue{id: ^issue_id} -> :ok end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, %Issue{state: :done}} =
          Issues.handle_linear_webhook(workspace, %{
            "type" => "Issue",
            "action" => "update",
            "data" => %{
              "id" => "lin_status_1",
              "teamId" => "lin_team_id",
              "identifier" => "STA-1",
              "title" => "A status to change",
              "state" => %{"name" => "Done", "type" => "completed"},
              "completedAt" => "2026-11-01T10:00:00.000Z",
              "updatedAt" => "2026-11-01T10:00:00.000Z"
            }
          })

        answer.(conn, %{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z", "2026-11-01T10:00:00.000Z")
      end)

      assert {:ok, %Issue{state: :done}} = Issues.set_issue_status(system_scope(), issue, @done)
    end

    test "a webhook after a pick's finish tells nobody again", %{
      project: project,
      issue: %{id: issue_id} = issue,
      answer: answer
    } do
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)
      expect(Pipeline, :handle_issue_finished, 1, fn %Issue{id: ^issue_id} -> :ok end)

      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z", "2026-11-01T10:00:00.000Z")
      end)

      assert {:ok, %Issue{state: :done}} = Issues.set_issue_status(system_scope(), issue, @done)

      assert {:ok, %Issue{state: :done}} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => "lin_status_1",
                   "teamId" => "lin_team_id",
                   "identifier" => "STA-1",
                   "title" => "A status to change",
                   "state" => %{"name" => "Done", "type" => "completed"},
                   "completedAt" => "2026-11-01T10:00:00.000Z",
                   "updatedAt" => "2026-11-01T10:00:00.000Z"
                 }
               })
    end

    test "a move out of Done clears the completed time and tells nobody", %{issue: issue, answer: answer} do
      issue =
        issue
        |> Issue.tracker_changeset(%{state: :done, state_name: "Done", completed_at: ~U[2026-11-01 08:00:00Z]})
        |> Repo.update!()

      reject(&Pipeline.handle_issue_finished/1)

      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "In Progress", "type" => "started"}, "2026-11-01T10:00:00.000Z", nil)
      end)

      assert {:ok, %Issue{state: :in_progress, state_name: "In Progress", completed_at: nil}} =
               Issues.set_issue_status(system_scope(), issue, @in_progress)

      refute_enqueued(worker: IssueFinished)
    end
  end

  describe "with a task" do
    test "a move to Done leaves the running task's stage and run unchanged", %{
      project: project,
      issue: issue,
      answer: answer
    } do
      {:ok, %Task{id: task_id}} = issue |> Repo.preload(:project) |> Pipeline.create_task(:engineer)
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, %Run{id: run_id}} =
        Pipeline.create_run(%{task_id: task_id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

      Req.Test.expect(Rail.Linear, fn conn ->
        answer.(conn, %{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z", "2026-11-01T10:00:00.000Z")
      end)

      assert {:ok, %Issue{state: :done}} = Issues.set_issue_status(system_scope(), issue, @done)

      assert %Task{stage: :engineer} = Repo.get!(Task, task_id)
      assert %Run{status: :running} = Repo.get!(Run, run_id)
      refute_enqueued(worker: AdvanceTrackerState)
    end
  end

  describe "on GitHub" do
    setup do
      test = self()

      # Each call the tracker makes, answered from the script the test gives it, in order.
      github = fn answers ->
        {:ok, script} = Agent.start_link(fn -> answers end)

        Req.Test.stub(Client, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          if conn.request_path =~ "access_tokens" do
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "ghs_token"})
          else
            send(test, {:github, conn.method, conn.request_path, body})
            answer = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)

            case answer do
              {status, json} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
              json -> Req.Test.json(conn, json)
            end
          end
        end)
      end

      %{github: github}
    end

    test "moving between open states swaps the rail: label and writes what GitHub answers", %{
      github_project: project,
      github: github
    } do
      issue = github_issue(project, %{number: 301, state: :in_progress, state_name: "In Progress"})
      live = github_issue_json(%{"node_id" => issue.external_id, "number" => 301})
      read = %{live | "labels" => [%{"name" => "rail:in-progress"}]}
      moved = %{read | "labels" => [%{"name" => "rail:in-review"}], "updated_at" => "2026-10-06T13:00:00.000000Z"}

      github.([read, [], [], moved])

      assert {:ok, %Issue{state: :in_review, state_name: "In Review"}} =
               Issues.set_issue_status(system_scope(), issue, %{id: "in_review", name: "In Review", state: :in_review})

      assert_received {:github, "POST", "/repos/example/test-gh/issues/301/labels", added}
      assert %{"labels" => ["rail:in-review"]} = Jason.decode!(added)
      assert_received {:github, "DELETE", "/repos/example/test-gh/issues/301/labels/rail%3Ain-progress", _empty}
    end

    test "Done closes the issue and carries GitHub's closed time", %{github_project: project, github: github} do
      issue = github_issue(project, %{number: 302, state: :in_review, state_name: "In Review"})
      read = github_issue_json(%{"node_id" => issue.external_id, "number" => 302})

      closed = %{
        read
        | "state" => "closed",
          "state_reason" => "completed",
          "closed_at" => "2026-10-06T13:00:00Z",
          "updated_at" => "2026-10-06T13:00:00.000000Z"
      }

      github.([read, closed, closed])

      assert {:ok, %Issue{state: :done, state_name: "Done", completed_at: ~U[2026-10-06 13:00:00Z]}} =
               Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})

      assert_received {:github, "PATCH", "/repos/example/test-gh/issues/302", patched}
      assert %{"state" => "closed", "state_reason" => "completed"} = Jason.decode!(patched)
    end

    test "an open status reopens a closed issue and labels it", %{github_project: project, github: github} do
      issue =
        github_issue(project, %{number: 303, state: :done, state_name: "Done", completed_at: ~U[2026-10-06 12:00:00Z]})

      closed =
        github_issue_json(%{
          "node_id" => issue.external_id,
          "number" => 303,
          "state" => "closed",
          "state_reason" => "completed",
          "closed_at" => "2026-10-06T12:00:00Z"
        })

      reopened = %{
        closed
        | "state" => "open",
          "state_reason" => "reopened",
          "closed_at" => nil,
          "labels" => [%{"name" => "rail:todo"}],
          "updated_at" => "2026-10-06T13:00:00.000000Z"
      }

      github.([closed, reopened, [], reopened])

      assert {:ok, %Issue{state: :todo, state_name: "Todo", completed_at: nil}} =
               Issues.set_issue_status(system_scope(), issue, %{id: "todo", name: "Todo", state: :todo})

      assert_received {:github, "PATCH", "/repos/example/test-gh/issues/303", patched}
      assert %{"state" => "open", "state_reason" => "reopened"} = Jason.decode!(patched)
      assert_received {:github, "POST", "/repos/example/test-gh/issues/303/labels", added}
      assert %{"labels" => ["rail:todo"]} = Jason.decode!(added)
    end

    test "a refusal leaves the row as it was", %{github_project: project, github: github} do
      %{id: issue_id} = issue = github_issue(project, %{number: 304, state: :backlog, state_name: "Backlog"})

      github.([{403, %{"message" => "Forbidden"}}])

      assert {:error, {:github_api_error, 403, _body}} =
               Issues.set_issue_status(system_scope(), issue, %{id: "todo", name: "Todo", state: :todo})

      assert %Issue{state: :backlog} = Repo.get!(Issue, issue_id)
    end
  end
end
