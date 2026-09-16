defmodule Rail.Pipeline.Actions.SyncReviewFindingsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Sync Findings Project",
        github_repo: "org/sync-findings",
        github_installation_id: 47_021,
        linear_workspace: %{
          name: "Sync Findings Workspace",
          external_id: "lin_ws_sync_findings",
          token: "lin_api_token_sync_findings",
          webhook_secret: "whsec_sync_findings"
        },
        linear_team_key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-findings",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sync_findings_1", "identifier" => "SYN-1", "title" => "Sync Findings"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Sync Findings"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    raised = %{
      key: "unhandled-nil",
      title: "Nil is not handled",
      detail: "The clause assumes a map.",
      suggestion: "Match the empty map first.",
      file: "lib/rail/example.ex",
      line: 12,
      severity: :major,
      recommendation: :fix,
      status: :open
    }

    %{task: task, raised: raised}
  end

  test "a finding starts at the reviewer's recommendation", %{task: task, raised: raised} do
    assert {:ok, [%ReviewFinding{key: "unhandled-nil", recommendation: :fix, decision: :fix}]} =
             Pipeline.sync_review_findings(task, [raised])
  end

  test "a finding the reviewer would leave starts dismissed", %{task: task, raised: raised} do
    assert {:ok, [%ReviewFinding{recommendation: :skip, decision: :skip}]} =
             Pipeline.sync_review_findings(task, [%{raised | recommendation: :skip}])
  end

  # A column the reviewer writes and the upsert's replace list forgets never
  # reaches a row that already exists, which reads in the UI as the reviewer
  # having said nothing.
  test "a second pass restates every field the reviewer wrote", %{task: task, raised: raised} do
    {:ok, _first} = Pipeline.sync_review_findings(task, [raised])

    restated = %{
      raised
      | title: "Nil is still not handled",
        detail: "The clause still assumes a map.",
        suggestion: "Match the empty map first.",
        file: "lib/rail/other.ex",
        line: 99,
        severity: :blocker,
        recommendation: :skip,
        status: :not_fixed
    }

    assert {:ok, [finding]} = Pipeline.sync_review_findings(task, [restated])

    for {field, value} <- Map.delete(restated, :key) do
      assert Map.fetch!(finding, field) == value, "#{field} was not restated"
    end
  end

  test "a second pass updates the finding it already raised", %{task: task, raised: raised} do
    {:ok, [%ReviewFinding{id: finding_id}]} = Pipeline.sync_review_findings(task, [raised])

    assert {:ok, [%ReviewFinding{id: ^finding_id, status: :fixed, detail: "The guard clause now covers it."}]} =
             Pipeline.sync_review_findings(task, [
               %{raised | status: :fixed, detail: "The guard clause now covers it."}
             ])
  end

  test "a second pass does not overrule the human", %{task: task, raised: raised} do
    {:ok, [finding]} = Pipeline.sync_review_findings(task, [raised])
    {:ok, _dismissed} = Pipeline.decide_review_finding(finding, :skip)

    assert {:ok, [%ReviewFinding{recommendation: :fix, decision: :skip, status: :not_fixed}]} =
             Pipeline.sync_review_findings(task, [%{raised | status: :not_fixed}])
  end

  test "a finding the reviewer stopped listing is kept", %{task: task, raised: raised} do
    {:ok, _first} = Pipeline.sync_review_findings(task, [raised])

    assert {:ok, findings} = Pipeline.sync_review_findings(task, [%{raised | key: "something-else"}])
    assert findings |> Enum.map(& &1.key) |> Enum.sort() == ["something-else", "unhandled-nil"]
  end

  test "a pass that found nothing leaves the task as it was", %{task: task} do
    assert {:ok, []} = Pipeline.sync_review_findings(task, [])
  end
end
