defmodule Rail.Pipeline.Actions.SaveReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_review_#{System.unique_integer([:positive])}")
    worktree = create_temp_git_repo()
    on_exit(fn -> File.rm_rf(scratch) end)

    %{
      task: %Task{id: "tsk_svr", scratch_path: scratch, worktree_path: worktree, issue: %Issue{identifier: "SVR-1"}},
      head: worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
    }
  end

  test "each pass is appended with its round, when, and the commit it read, and said to the page", %{
    task: task,
    head: head
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:tsk_svr")

    assert Pipeline.read_review(task) == []
    assert {:ok, %{round: 1, head: ^head, finished_at: nil, saved_at: %DateTime{}}} = Pipeline.save_review(task)
    assert {:ok, %{round: 2, head: ^head}} = Pipeline.save_review(task)
    assert [%{round: 1, head: ^head}, %{round: 2, head: ^head}] = Pipeline.read_review(task)
    assert_received {:output_saved, "tsk_svr"}
  end

  test "a worktree no longer on disk saves a pass with no commit", %{task: task} do
    assert {:ok, %{round: 1, head: nil}} = Pipeline.save_review(%{task | worktree_path: "/nonexistent/svr"})
  end
end
