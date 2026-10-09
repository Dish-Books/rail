defmodule Rail.Pipeline.Actions.SaveDemoTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Workers.EncodeDemo
  alias Rail.Tools

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_svd_1", "identifier" => "SVD-1", "title" => "Save Demo"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Demo"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: Repo.preload(task, :issue)}
  end

  test "a write-up is written where read_demo reads it, and broadcast", %{task: %{id: task_id} = task} do
    assert {:ok, %Demo{title: "Rounds of comments", commit: nil}} =
             Pipeline.save_demo(task, %{"title" => "Rounds of comments", "summary" => "Comments go as one round."})

    assert %Demo{title: "Rounds of comments", summary: "Comments go as one round.", not_shown: nil} =
             Pipeline.read_demo(task)

    assert_received {:output_saved, ^task_id}
  end

  # The demo is of what is on the branch now, and the panel says which commit that was.
  test "a write-up says the commit it was saved on", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    head_sha = String.trim(git!(task.worktree_path, ["rev-parse", "HEAD"]))

    assert {:ok, %Demo{commit: ^head_sha}} =
             Pipeline.save_demo(task, %{"title" => "Rounds of comments", "summary" => "Comments go as one round."})

    assert %Demo{commit: ^head_sha} = Pipeline.read_demo(Repo.preload(task, :issue))
  end

  # Saving is how the recorder says the take is over, so the encode starts then rather than when Review ends.
  test "saving stops the recording and queues its encode", %{task: %{id: task_id} = task} do
    expect(Tools, :stop_browser_recording, fn %{id: ^task_id} -> nil end)

    assert {:ok, %Demo{}} = Pipeline.save_demo(task, %{"title" => "Filters", "summary" => "It filters."})
    assert_enqueued(worker: EncodeDemo, args: %{task_id: task_id})
  end

  test "a write-up saved again queues no second encode", %{task: %{id: task_id} = task} do
    assert {:ok, %Demo{}} = Pipeline.save_demo(task, %{"title" => "Filters", "summary" => "It filters."})
    assert {:ok, %Demo{}} = Pipeline.save_demo(task, %{"title" => "Filters", "summary" => "It filters by vendor."})

    assert [%Oban.Job{args: %{"task_id" => ^task_id}}] = all_enqueued(worker: EncodeDemo)
  end

  test "a write-up with no summary is refused", %{task: task} do
    reject(&Tools.stop_browser_recording/1)

    assert {:error, changeset} = Pipeline.save_demo(task, %{"title" => "Rounds of comments"})
    assert %{summary: ["can't be blank"]} = errors_on(changeset)
    assert Pipeline.read_demo(task) == nil
    refute_enqueued(worker: EncodeDemo)
  end
end
