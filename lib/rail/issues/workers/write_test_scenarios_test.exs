defmodule Rail.Issues.Workers.WriteTestScenariosTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.WriteTestScenarios
  alias Rail.Tools

  test "a ticket nobody asked scenarios for, or one that is gone, runs no agent", %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Export keeps icons"})
    reject(&Tools.run_agent/3)

    assert :ok = perform_job(WriteTestScenarios, %{issue_id: issue.id, merge_sha: "3c9a1f0e2b"})
    assert :ok = perform_job(WriteTestScenarios, %{issue_id: "iss_gone", merge_sha: "3c9a1f0e2b"})
  end

  test "one job per ticket waits at a time" do
    args = %{issue_id: "iss_once", merge_sha: "3c9a1f0e2b"}
    {:ok, %Oban.Job{conflict?: false}} = args |> WriteTestScenarios.new() |> Oban.insert()
    assert {:ok, %Oban.Job{conflict?: true}} = args |> WriteTestScenarios.new() |> Oban.insert()
  end
end
