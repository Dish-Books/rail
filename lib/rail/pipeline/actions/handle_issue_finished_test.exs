defmodule Rail.Pipeline.Actions.HandleIssueFinishedTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Workers.AdvanceSplit

  setup %{project: project} do
    for {id, identifier} <- [{"lin_hif_1", "HIF-1"}, {"lin_hif_2", "HIF-2"}] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => id, "identifier" => identifier, "title" => identifier}
            }
          }
        })
      end)
    end

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "HIF-1"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    {:ok, child_issue} = Issues.create_issue(system_scope(), project, %{title: "HIF-2", parent: parent_issue})

    {:ok, _child} =
      Pipeline.create_child_task(parent, child_issue, %{number: 1, builds_on: [], plan: "## Implementation plan"})

    %{parent: parent, parent_issue: parent_issue, child_issue: child_issue}
  end

  test "a child's issue queues one job for its parent, and any other issue queues nothing", %{
    parent: parent,
    parent_issue: parent_issue,
    child_issue: child_issue
  } do
    assert {:ok, %Oban.Job{}} = Pipeline.handle_issue_finished(child_issue)
    assert {:ok, %Oban.Job{conflict?: true}} = Pipeline.handle_issue_finished(child_issue)
    assert [%Oban.Job{}] = all_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent.id})

    assert :ok = Pipeline.handle_issue_finished(parent_issue)
    assert length(all_enqueued(worker: AdvanceSplit)) == 1
  end
end
