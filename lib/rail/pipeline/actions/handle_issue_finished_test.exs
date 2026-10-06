defmodule Rail.Pipeline.Actions.HandleIssueFinishedTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Pipeline
  alias Rail.Pipeline.Workers.AdvanceSplit

  test "a child's issue queues one job for its parent, and any other issue queues nothing", %{project: project} do
    {parent, [child]} = split_task(project, "HIF-1", [{"HIF-2", []}])

    assert {:ok, %Oban.Job{}} = Pipeline.handle_issue_finished(child.issue)
    assert {:ok, %Oban.Job{conflict?: true}} = Pipeline.handle_issue_finished(child.issue)
    assert [%Oban.Job{}] = all_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent.id})

    assert :ok = Pipeline.handle_issue_finished(parent.issue)
    assert length(all_enqueued(worker: AdvanceSplit)) == 1
  end
end
