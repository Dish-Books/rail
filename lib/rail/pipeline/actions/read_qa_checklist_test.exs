defmodule Rail.Pipeline.Actions.ReadQaChecklistTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Read Checklist Project",
        github_repo: "org/read-checklist",
        github_installation_id: 47_045,
        linear_workspace: %{
          name: "Read Checklist Workspace",
          external_id: "lin_ws_read_checklist",
          token: "lin_api_token_read_checklist",
          webhook_secret: "whsec_read_checklist"
        },
        linear_team_key: "RCL",
        default_branch: "main",
        clone_path: "/tmp/repos/read-checklist",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rcl_1", "identifier" => "RCL-1", "title" => "Read Checklist"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Checklist"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    qa_dir = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, path: Path.join(qa_dir, "checklist.json")}
  end

  test "reads back what the pass wrote, outcomes and all", %{task: task, path: path} do
    File.write!(path, """
    {"checks": [
      {"key": "bill-saves", "title": "A bill saves", "criterion": "A bill saves", "outcome": "pass", "note": "it did"},
      {"key": "totals", "title": "The totals agree", "outcome": "pending", "note": null}
    ]}
    """)

    assert {:ok, %QaChecklist{checks: [saved, totals]}} = Pipeline.read_qa_checklist(task)
    assert %{key: "bill-saves", outcome: :pass, note: "it did", criterion: "A bill saves"} = saved
    assert %{key: "totals", outcome: :pending, note: nil} = totals
  end

  # Named rather than `nil`, because the caller that marks a row off has two ways
  # to find nothing and they are different things to tell the agent.
  test "a pass that has not written one yet says which nothing that is", %{task: task} do
    assert {:error, :qa_checklist_not_found} = Pipeline.read_qa_checklist(task)
  end

  # A pass killed mid-write leaves half a line. The panel shows what it showed
  # before rather than an error about a file the human never asked about.
  test "a file that is not a checklist reads as none", %{task: task, path: path} do
    for content <- ["", "not json at all", ~s({"checks": "soon"}), ~s({"checks": [{"title": "no key"}]})] do
      File.write!(path, content)

      assert {:error, :qa_checklist_not_found} = Pipeline.read_qa_checklist(task)
    end
  end
end
