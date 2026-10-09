defmodule Rail.Pipeline.Utils.MarkPullRequestReadyTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog
  import Rail.Pipeline.Utils.MarkPullRequestReady

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_mprr_1", "identifier" => "MPR-1", "title" => "Mark Ready"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Mark Ready"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 42, pr_is_draft: true})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "a pull request GitHub will not take out of draft leaves the task as it was, and says so in the log", %{
    task: task
  } do
    Req.Test.stub(Rail.GitHub.Client, &Plug.Conn.send_resp(&1, 500, "down"))

    log = capture_log(fn -> assert %Task{pr_is_draft: true} = mark_pull_request_ready(task) end)

    assert log =~ "#42 ready for review"
    assert %Task{pr_is_draft: true} = Repo.reload!(task)
  end
end
