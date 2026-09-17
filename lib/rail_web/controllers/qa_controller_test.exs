defmodule RailWeb.QaControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Users

  setup %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_qa_controller",
        login: "qa_controller_user",
        email: "qa_controller_user@example.com"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Qa Controller Project",
        github_repo: "org/qa-controller",
        github_installation_id: 47_038,
        linear_workspace: %{
          name: "Qa Controller Workspace",
          external_id: "lin_ws_qa_controller",
          token: "lin_api_token_qa_controller",
          webhook_secret: "whsec_qa_controller"
        },
        linear_team_key: "QCT",
        default_branch: "main",
        clone_path: "/tmp/repos/qa-controller",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_qa_controller_1", "identifier" => "QCT-1", "title" => "Qa Controller"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Qa Controller"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    evidence_dir = Path.join([task.scratch_path, "qa", "evidence"])
    File.mkdir_p!(evidence_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(Path.join(evidence_dir, "total.png"), "png bytes")
    File.write!(Path.join(evidence_dir, "server.log"), "** (RuntimeError) boom")
    File.write!(Path.join(evidence_dir, "unnamed.png"), "nobody points at this")

    {:ok, _raised} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "total-unrounded",
          title: "The total renders as $1234.5",
          check: "A bill's total reads as money",
          severity: :major,
          recommendation: :fix,
          status: :open,
          evidence: [
            %{name: "the total", kind: :screenshot, path: "evidence/total.png"},
            %{name: "the stacktrace", kind: :log, path: "evidence/server.log"},
            %{name: "the stored amount", kind: :query, text: "1234.50"},
            %{name: "a file QA wrote and then deleted", kind: :screenshot, path: "evidence/gone.png"}
          ]
        }
      ])

    %{conn: log_in_user(conn, user), task: task}
  end

  test "serves the screenshot a finding names", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/total-unrounded/evidence/0")

    assert response(conn, 200) == "png bytes"
    assert response_content_type(conn, :png) =~ "image/png"
  end

  test "and a log it captured", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/total-unrounded/evidence/1")

    assert response(conn, 200) == "** (RuntimeError) boom"
  end

  # The path is looked up, never taken from the URL: the worst a caller can do
  # with a key or an index it invented is get a 404.
  test "serves nothing a finding does not name", %{conn: conn, task: task} do
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/2") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/3") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/9") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/-1") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/first") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/no-such-finding/evidence/0") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/qa/total-unrounded/evidence/0") |> response(404)
  end

  test "a stranger is sent to sign in rather than served", %{task: task} do
    conn = get(build_conn(), ~p"/tasks/#{task.id}/qa/total-unrounded/evidence/0")

    assert redirected_to(conn) =~ "/sign-in"
  end
end
