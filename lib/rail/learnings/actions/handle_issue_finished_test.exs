defmodule Rail.Learnings.Actions.HandleIssueFinishedTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Workers.IssueFinished

  test "queues one job and changes no rows, and a second call while it waits adds none", %{project: project} do
    task = learnings_task(project, "FIN-1")

    assert {:ok, %Oban.Job{}} = Learnings.handle_issue_finished(task.issue)
    assert {:ok, %Oban.Job{conflict?: true}} = Learnings.handle_issue_finished(task.issue)

    assert [_one] = all_enqueued(worker: IssueFinished, args: %{issue_id: task.issue_id})
    assert %{learnings_extracted_at: nil} = Repo.reload!(task)
  end
end
