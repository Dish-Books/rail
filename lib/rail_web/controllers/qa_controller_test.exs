defmodule RailWeb.QaControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_qa_controller",
        login: "qa_controller_user",
        email: "qa_controller_user@example.com"
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
    File.write!(Path.join(evidence_dir, "script-runs~the-log.log"), "wrote 3 rows")
    File.write!(Path.join(evidence_dir, "invoice~the-invoice.pdf"), "%PDF-1.7")
    File.write!(Path.join(evidence_dir, "export~the-export.bin"), <<0, 159, 146, 150>>)
    File.write!(Path.join(evidence_dir, "page~the-page.html"), "<script>alert(1)</script>")
    File.write!(Path.join(evidence_dir, "bill.jpg"), "jpeg bytes")
    File.write!(Path.join(evidence_dir, "page.html"), "<script>alert(1)</script>")

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
            %{name: "a file QA wrote and then deleted", kind: :screenshot, path: "evidence/gone.png"},
            %{name: "a page it wrote", kind: :log, path: "evidence/page.html"},
            %{name: "the bill", kind: :screenshot, path: "evidence/bill.jpg"},
            %{name: "a log QA wrote and then deleted", kind: :log, path: "evidence/gone.log"}
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

  # The agent chose the name of anything a finding cites, so the type comes from
  # what the file holds rather than from its extension.
  test "serves a page a finding cites as text rather than as a page", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/total-unrounded/evidence/4")

    assert response(conn, 200) == "<script>alert(1)</script>"
    assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
  end

  # The name `qa_file` handed back is the name the agent was told to cite.
  test "serves a filed log a finding cites by the name Rail gave it", %{conn: conn, task: task} do
    {:ok, _raised} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "cites-filed",
          title: "The script reports a failure",
          check: "script-runs",
          severity: :minor,
          recommendation: :fix,
          status: :open,
          evidence: [%{name: "the log", kind: :log, path: "evidence/script-runs~the-log.log"}]
        }
      ])

    conn = get(conn, ~p"/tasks/#{task.id}/qa/cites-filed/evidence/0")

    assert response(conn, 200) == "wrote 3 rows"
    assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
  end

  test "a screenshot a finding cites is still served as a picture", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/total-unrounded/evidence/5")

    assert response(conn, 200) == "jpeg bytes"
    assert ["image/jpeg" <> _charset] = get_resp_header(conn, "content-type")
  end

  # Watching a pass means seeing what it saw before any finding names it, so the
  # roll is served straight out of the directory - matched against it, never
  # joined onto it.
  test "serves a screenshot no finding names yet", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/evidence/unnamed.png")

    assert response(conn, 200) == "nobody points at this"
    assert response_content_type(conn, :png) =~ "image/png"
  end

  test "serves nothing the directory does not hold", %{conn: conn, task: task} do
    assert conn |> get(~p"/tasks/#{task.id}/qa/evidence/invented.png") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/evidence/server.log") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/qa/evidence/unnamed.png") |> response(404)
    assert conn |> get("/tasks/#{task.id}/qa/evidence/..%2F..%2Fsecret.log") |> response(404)
  end

  # A log filed against a check is read in the browser, and as text whatever the
  # browser would have guessed it was.
  test "serves a filed log as text", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/evidence/script-runs~the-log.log")

    assert response(conn, 200) == "wrote 3 rows"
    assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    # Filing again under the same check and caption replaces the file under the
    # same name, so a browser has to ask again rather than show the last pass.
    assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
  end

  test "serves a filed PDF for the browser to open", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/evidence/invoice~the-invoice.pdf")

    assert response(conn, 200) == "%PDF-1.7"
    assert ["application/pdf" <> _charset] = get_resp_header(conn, "content-type")
    assert [] = get_resp_header(conn, "content-disposition")
  end

  test "serves a filed binary as a download", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/evidence/export~the-export.bin")

    assert response(conn, 200) == <<0, 159, 146, 150>>
    assert ["application/octet-stream" <> _charset] = get_resp_header(conn, "content-type")
    assert ["attachment" <> _filename] = get_resp_header(conn, "content-disposition")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
  end

  # The agent wrote it, so it never runs as a page on Rail's own origin.
  test "serves a filed page as text rather than as a page", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/qa/evidence/page~the-page.html")

    assert response(conn, 200) == "<script>alert(1)</script>"
    assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
  end

  # The path is looked up, never taken from the URL: the worst a caller can do
  # with a key or an index it invented is get a 404.
  test "serves nothing a finding does not name", %{conn: conn, task: task} do
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/2") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/3") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/qa/total-unrounded/evidence/6") |> response(404)
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
