defmodule Rail.Pipeline.Actions.SyncQaFindingsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Sync Qa Project",
        github_repo: "org/sync-qa",
        github_installation_id: 47_031,
        linear_workspace: %{
          name: "Sync Qa Workspace",
          external_id: "lin_ws_sync_qa",
          token: "lin_api_token_sync_qa",
          webhook_secret: "whsec_sync_qa"
        },
        linear_team_key: "SYQ",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-qa",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sync_qa_1", "identifier" => "SYQ-1", "title" => "Sync Qa"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Sync Qa"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "a finding arrives with nobody having ruled on it", %{task: task} do
    findings = [%{key: "one", title: "One", check: "A check", severity: :major, recommendation: :fix, status: :open}]

    assert {:ok, [%QaFinding{key: "one", decision: nil, recommendation: :fix}]} =
             Pipeline.sync_qa_findings(task, findings)
  end

  # A column QA writes that the restate list forgets is a column that never
  # reaches a row already on the task, which is the bug this catches.
  test "a later pass restates everything QA wrote", %{task: task} do
    first = %{
      key: "one",
      title: "First title",
      check: "First check",
      criterion: "First criterion",
      screen: "/first",
      steps: "1. first",
      expected: "first expected",
      observed: "first observed",
      detail: "First detail",
      suggestion: "First suggestion",
      severity: :nit,
      recommendation: :skip,
      status: :open,
      caused_by_change: false,
      evidence: [%{name: "first shot", kind: :screenshot, path: "evidence/first.png"}]
    }

    {:ok, _first} = Pipeline.sync_qa_findings(task, [first])

    second = %{
      first
      | title: "Second title",
        check: "Second check",
        criterion: "Second criterion",
        screen: "/second",
        steps: "1. second",
        expected: "second expected",
        observed: "second observed",
        detail: "Second detail",
        suggestion: "Second suggestion",
        severity: :blocker,
        recommendation: :fix,
        status: :not_fixed,
        caused_by_change: true,
        evidence: [%{name: "second shot", kind: :log, text: "boom"}]
    }

    assert {:ok, [%QaFinding{} = synced]} = Pipeline.sync_qa_findings(task, [second])

    assert %{
             title: "Second title",
             check: "Second check",
             criterion: "Second criterion",
             screen: "/second",
             steps: "1. second",
             expected: "second expected",
             observed: "second observed",
             detail: "Second detail",
             suggestion: "Second suggestion",
             severity: :blocker,
             recommendation: :fix,
             status: :not_fixed,
             caused_by_change: true
           } = synced

    assert [%{name: "second shot", kind: :log, text: "boom"}] = synced.evidence
  end

  test "a later pass never overrules the human", %{task: task} do
    finding = %{key: "one", title: "One", check: "A check", severity: :major, recommendation: :fix, status: :open}

    {:ok, [raised]} = Pipeline.sync_qa_findings(task, [finding])
    {:ok, _dismissed} = Pipeline.decide_qa_finding(raised, :skip)

    assert {:ok, [%QaFinding{decision: :skip, recommendation: :fix}]} =
             Pipeline.sync_qa_findings(task, [%{finding | recommendation: :fix}])
  end

  # A pass that stopped listing a finding has said nothing about it, which is
  # not the same as saying it is gone.
  test "a key a later pass dropped stays on the task", %{task: task} do
    kept = %{key: "kept", title: "Kept", check: "A check", severity: :nit, recommendation: :skip, status: :open}
    gone = %{kept | key: "gone", title: "Gone"}

    {:ok, _both} = Pipeline.sync_qa_findings(task, [kept, gone])

    assert {:ok, synced} = Pipeline.sync_qa_findings(task, [kept])
    assert Enum.map(synced, & &1.key) == ["kept", "gone"]
  end

  test "a pass with nothing in it changes nothing", %{task: task} do
    finding = %{key: "one", title: "One", check: "A check", severity: :major, recommendation: :fix, status: :open}
    {:ok, _raised} = Pipeline.sync_qa_findings(task, [finding])

    assert {:ok, [%QaFinding{key: "one"}]} = Pipeline.sync_qa_findings(task, [])
  end
end
