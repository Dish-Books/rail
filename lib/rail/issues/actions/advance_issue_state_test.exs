defmodule Rail.Issues.Actions.AdvanceIssueStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Repo

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_advance_action_1", "identifier" => "ADA-1", "title" => "Advance Action Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Advance Action Issue"})

    %{issue: issue}
  end

  test "queues the Linear move rather than making it", %{issue: issue} do
    assert {:ok, %Oban.Job{}} = Issues.advance_issue_state(issue)

    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: issue.id})
  end

  # The job reads the task's stage when it runs, so the one already queued covers the later stage too.
  test "an issue with a move already queued or running gets no second job", %{issue: issue} do
    {:ok, %Oban.Job{id: job_id}} = Issues.advance_issue_state(issue)

    for state <- ["available", "scheduled", "executing", "retryable"] do
      Oban.Job |> Repo.get!(job_id) |> Ecto.Changeset.change(state: state) |> Repo.update!()

      assert {:ok, %Oban.Job{id: ^job_id, conflict?: true}} = Issues.advance_issue_state(issue)
    end
  end

  test "a move that has finished does not block the next one", %{issue: issue} do
    {:ok, %Oban.Job{id: finished_id} = finished} = Issues.advance_issue_state(issue)
    finished |> Ecto.Changeset.change(state: "completed") |> Repo.update!()

    assert {:ok, %Oban.Job{id: next_id, conflict?: false}} = Issues.advance_issue_state(issue)
    assert next_id != finished_id
  end

  # A job left retrying through a Linear outage is older than Oban's default window.
  test "a move queued long ago still blocks a second one", %{issue: issue} do
    {:ok, %Oban.Job{id: job_id} = queued} = Issues.advance_issue_state(issue)

    queued
    |> Ecto.Changeset.change(state: "retryable", inserted_at: DateTime.shift(DateTime.utc_now(), day: -1))
    |> Repo.update!()

    assert {:ok, %Oban.Job{id: ^job_id, conflict?: true}} = Issues.advance_issue_state(issue)
  end
end
