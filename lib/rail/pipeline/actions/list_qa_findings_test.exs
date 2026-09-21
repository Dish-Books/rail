defmodule Rail.Pipeline.Actions.ListQaFindingsTest do
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
        name: "List Qa Project",
        github_repo: "org/list-qa",
        github_installation_id: 47_032,
        linear_workspace: %{
          name: "List Qa Workspace",
          external_id: "lin_ws_list_qa",
          token: "lin_api_token_list_qa",
          webhook_secret: "whsec_list_qa"
        },
        linear_team_key: "LSQ",
        default_branch: "main",
        clone_path: "/tmp/repos/list-qa",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_list_qa_1", "identifier" => "LSQ-1", "title" => "List Qa"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Qa"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "what this change broke comes first, worst first within it", %{task: task} do
    findings =
      for {key, severity, caused} <- [
            {"old-nit", :nit, false},
            {"old-blocker", :blocker, false},
            {"new-minor", :minor, true},
            {"new-blocker", :blocker, true}
          ] do
        %{
          key: key,
          title: key,
          check: "A check",
          severity: severity,
          recommendation: :fix,
          status: :open,
          caused_by_change: caused
        }
      end

    {:ok, _synced} = Pipeline.sync_qa_findings(task, findings)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == [
             "new-blocker",
             "new-minor",
             "old-blocker",
             "old-nit"
           ]
  end

  test "what the human dismissed sinks below everything still standing", %{task: task} do
    findings =
      for {key, severity} <- [{"dismissed-blocker", :blocker}, {"standing-nit", :nit}] do
        %{key: key, title: key, check: "A check", severity: severity, recommendation: :fix, status: :open}
      end

    {:ok, [dismissed, _standing]} = Pipeline.sync_qa_findings(task, findings)
    {:ok, _ruled} = Pipeline.decide_qa_finding(dismissed, :skip)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["standing-nit", "dismissed-blocker"]
  end

  # Nothing moves until every finding has been ruled on, so the ones asking for a
  # ruling are the ones to read - above a worse one already settled.
  test "what is waiting on a human comes before what is settled", %{task: task} do
    findings =
      for {key, severity} <- [{"decided-blocker", :blocker}, {"undecided-nit", :nit}] do
        %{key: key, title: key, check: "A check", severity: severity, recommendation: :fix, status: :open}
      end

    {:ok, [decided, _waiting]} = Pipeline.sync_qa_findings(task, findings)
    {:ok, _ruled} = Pipeline.decide_qa_finding(decided, :fix)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["undecided-nit", "decided-blocker"]
  end

  # Fixed is finished with, and dismissed is the human's last word: both sit
  # under what is still being worked through, in that order.
  test "what is fixed sits under what is open, and dismissed under that", %{task: task} do
    {:ok, [fixed, dismissed, _open]} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "a-blocker",
          title: "A blocker",
          check: "a-check",
          severity: :blocker,
          recommendation: :fix,
          status: :fixed
        },
        %{key: "a-major", title: "A major", check: "a-check", severity: :major, recommendation: :fix, status: :open},
        %{key: "a-nit", title: "A nit", check: "a-check", severity: :nit, recommendation: :fix, status: :open}
      ])

    {:ok, _ruled} = Pipeline.decide_qa_finding(dismissed, :skip)
    {:ok, _decided} = Pipeline.decide_qa_finding(fixed, :fix)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["a-nit", "a-blocker", "a-major"]
  end

  test "a task QA has not reached has nothing to list", %{task: task} do
    assert Pipeline.list_qa_findings(task) == []
  end
end
