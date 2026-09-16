defmodule Rail.Pipeline.Actions.ListReviewFindingsTest do
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
        name: "List Findings Project",
        github_repo: "org/list-findings",
        github_installation_id: 47_024,
        linear_workspace: %{
          name: "List Findings Workspace",
          external_id: "lin_ws_list_findings",
          token: "lin_api_token_list_findings",
          webhook_secret: "whsec_list_findings"
        },
        linear_team_key: "LSF",
        default_branch: "main",
        clone_path: "/tmp/repos/list-findings",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_lsf_1", "identifier" => "LSF-1", "title" => "List Findings"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Findings"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "worst first, whatever order they were raised in", %{task: task} do
    {:ok, _synced} =
      Pipeline.sync_review_findings(task, [
        %{key: "a-nit", title: "A nit", severity: :nit, recommendation: :skip, status: :open},
        %{key: "a-blocker", title: "A blocker", severity: :blocker, recommendation: :fix, status: :open},
        %{key: "a-minor", title: "A minor", severity: :minor, recommendation: :fix, status: :open},
        %{key: "a-major", title: "A major", severity: :major, recommendation: :fix, status: :open}
      ])

    assert ["a-blocker", "a-major", "a-minor", "a-nit"] =
             task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  # A dismissed finding is still shown, because what was dealt with is what makes
  # "what is left" mean anything, but it is no longer something to read past.
  test "what the human dismissed sinks below what still stands", %{task: task} do
    {:ok, [blocker, _nit]} =
      Pipeline.sync_review_findings(task, [
        %{key: "a-blocker", title: "A blocker", severity: :blocker, recommendation: :fix, status: :open},
        %{key: "a-nit", title: "A nit", severity: :nit, recommendation: :fix, status: :open}
      ])

    assert ["a-blocker", "a-nit"] = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)

    {:ok, _dismissed} = Pipeline.decide_review_finding(blocker, :skip)

    assert ["a-nit", "a-blocker"] = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  test "a task nobody has reviewed has no findings", %{task: task} do
    assert Pipeline.list_review_findings(task) == []
  end
end
