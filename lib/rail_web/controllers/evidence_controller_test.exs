defmodule RailWeb.EvidenceControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_evidence_controller",
        login: "evidence_controller_user",
        email: "evidence_controller_user@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_evidence_controller_1", "identifier" => "ECT-1", "title" => "Evidence Controller"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Evidence Controller"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(Path.join(qa, "shots/total.png"), "png bytes")
    File.write!(Path.join(qa, "server.log"), "** (RuntimeError) boom")
    File.write!(Path.join(qa, "page.html"), "<script>alert(1)</script>")
    File.write!(Path.join(qa, "bill.jpg"), "jpeg bytes")
    File.write!(Path.join(qa, "invoice.pdf"), "%PDF-1.7")
    File.write!(Path.join(qa, "export.bin"), <<0, 159, 146, 150>>)

    {:ok, %Finding{evidence: [%FindingEvidence{path: shot} | _rest]}} =
      Pipeline.save_finding(task, %{
        key: "total-unrounded",
        kind: :screen,
        raised_by: :explorer,
        title: "The total renders as $1234.5",
        problem: "A bill's total shows one decimal.",
        screen: "Invoices",
        steps: ["Open an invoice"],
        check: "A bill's total reads as money",
        fix: "Round the total to cents.",
        why: "Money reads in cents.",
        rule: "Totals show two decimals.",
        severity: :major,
        recommendation: :fix,
        places: [%{screen: "Invoices"}],
        evidence: [
          %{name: "the total", kind: :screenshot, path: "shots/total.png"},
          %{name: "the stacktrace", kind: :log, path: "server.log"},
          %{name: "the stored amount", kind: :query, text: "1234.50"},
          %{name: "a page it wrote", kind: :log, path: "page.html"},
          %{name: "the bill", kind: :screenshot, path: "bill.jpg"},
          %{name: "the invoice", kind: :log, path: "invoice.pdf"},
          %{name: "the export", kind: :log, path: "export.bin"}
        ]
      })

    %{conn: log_in_user(conn, user), task: task, qa: qa, shot: shot}
  end

  test "serves the screenshot a finding attached", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/0")

    assert response(conn, 200) == "png bytes"
    assert response_content_type(conn, :png) =~ "image/png"
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
  end

  # Copied when attached, so a later pass writing over the original changes nothing served.
  test "serves the copy, whatever became of the file it was copied from", %{conn: conn, task: task, qa: qa} do
    File.write!(Path.join(qa, "shots/total.png"), "a later pass's picture")

    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/0")

    assert response(conn, 200) == "png bytes"
  end

  test "serves a log as text", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/1")

    assert response(conn, 200) == "** (RuntimeError) boom"
    assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
  end

  # The agent chose the name, so the type comes from what the file holds, and it never runs as a page.
  test "serves a page a finding attached as text rather than as a page", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/3")

    assert response(conn, 200) == "<script>alert(1)</script>"
    assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
  end

  test "a jpeg is served as a picture", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/4")

    assert response(conn, 200) == "jpeg bytes"
    assert ["image/jpeg" <> _charset] = get_resp_header(conn, "content-type")
  end

  test "serves a PDF for the browser to open", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/5")

    assert response(conn, 200) == "%PDF-1.7"
    assert ["application/pdf" <> _charset] = get_resp_header(conn, "content-type")
    assert [] = get_resp_header(conn, "content-disposition")
  end

  test "serves a binary as a download", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/6")

    assert response(conn, 200) == <<0, 159, 146, 150>>
    assert ["application/octet-stream" <> _charset] = get_resp_header(conn, "content-type")
    assert ["attachment" <> _filename] = get_resp_header(conn, "content-disposition")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
  end

  # The path is looked up, never taken from the URL: the worst a caller can do with a key or an index
  # it invented is get a 404.
  test "serves nothing a finding does not name", %{conn: conn, task: task} do
    assert conn |> get(~p"/tasks/#{task.id}/findings/total-unrounded/evidence/2") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/findings/total-unrounded/evidence/9") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/findings/total-unrounded/evidence/-1") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/findings/total-unrounded/evidence/first") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/findings/no-such-finding/evidence/0") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/findings/total-unrounded/evidence/0") |> response(404)
    assert conn |> get("/tasks/#{task.id}/findings/total-unrounded/evidence/..%2F..%2Fsecret.log") |> response(404)
  end

  # A link swapped in for the copy could name any file on the machine.
  test "a copy swapped for a symlink is not served", %{conn: conn, task: task, qa: qa, shot: shot} do
    outside = Path.join(System.tmp_dir!(), "ect-outside-#{System.unique_integer([:positive])}.png")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)
    File.rm!(Path.join(qa, shot))
    File.ln_s!(outside, Path.join(qa, shot))

    assert conn |> get(~p"/tasks/#{task.id}/findings/total-unrounded/evidence/0") |> response(404) == "Not found"
  end

  test "a stranger is sent to sign in rather than served", %{task: task} do
    conn = get(build_conn(), ~p"/tasks/#{task.id}/findings/total-unrounded/evidence/0")

    assert redirected_to(conn) =~ "/sign-in"
  end

  test "evidence of a task in a project the user cannot access is not found", %{conn: conn, task: task} do
    {:ok, outsider} =
      Users.register_oauth_user(%{
        github_id: "gh_evidence_outsider",
        login: "evidence_outsider",
        email: "evidence_outsider@example.com"
      })

    {:ok, outsider} = Users.update_user(system_scope(), outsider, %{project_ids: ["prj_other"]})
    conn = log_in_user(conn, outsider)

    assert conn |> get(~p"/tasks/#{task.id}/findings/total-unrounded/evidence/0") |> response(404) == "Not found"
  end
end
