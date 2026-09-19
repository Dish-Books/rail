defmodule Rail.Pipeline.Actions.ListQaEvidenceTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "List Evidence Project",
        github_repo: "org/list-evidence",
        github_installation_id: 47_052,
        linear_workspace: %{
          name: "List Evidence Workspace",
          external_id: "lin_ws_list_evidence",
          token: "lin_api_token_list_evidence",
          webhook_secret: "whsec_list_evidence"
        },
        linear_team_key: "LEV",
        default_branch: "main",
        clone_path: "/tmp/repos/list-evidence",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_lev_1", "identifier" => "LEV-1", "title" => "List Evidence"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Evidence"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    directory = Path.join([task.scratch_path, "qa", "evidence"])
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, directory: directory}
  end

  # Rail made every one of these names, so the check and the caption come back
  # out of it rather than out of anywhere that had to be kept in step.
  test "reads the check and the caption back out of the name", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "bill-saves~the-saved-bill.jpg"), "jpeg")

    assert [%{name: "The saved bill", file: "bill-saves~the-saved-bill.jpg", check: "bill-saves"}] =
             Pipeline.list_qa_evidence(task)
  end

  # A pass can photograph something before it has a checklist to file it
  # against, and that picture is still a picture.
  test "a shot filed against no check still lists", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "the-login-screen.png"), "png")

    assert [%{name: "The login screen", check: nil}] = Pipeline.list_qa_evidence(task)
  end

  # Newest first, because the one a reader wants while a pass is going is the
  # one it just took.
  test "newest first, and only what a browser photographed", %{task: task, directory: directory} do
    for {file, seconds} <- [{"totals~first.jpg", 1_700_000_000}, {"totals~second.jpg", 1_700_000_060}] do
      path = Path.join(directory, file)
      File.write!(path, "jpeg")
      File.touch!(path, seconds)
    end

    File.write!(Path.join(directory, "server.log"), "** (RuntimeError) boom")

    assert [%{file: "totals~second.jpg"}, %{file: "totals~first.jpg"}] = Pipeline.list_qa_evidence(task)
  end

  test "a pass that photographed nothing has no directory and no pictures", %{task: task, directory: directory} do
    File.rm_rf!(directory)

    assert [] = Pipeline.list_qa_evidence(task)
  end
end
