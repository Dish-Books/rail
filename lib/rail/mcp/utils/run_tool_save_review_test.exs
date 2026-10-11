defmodule Rail.Mcp.Utils.RunToolSaveReviewTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveReview

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "closing a round is receipted with its number, whatever arrived with it" do
    scratch = Path.join(System.tmp_dir!(), "rt_save_review_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{scratch_path: scratch, worktree_path: Path.join(scratch, "worktree"), issue: %Issue{identifier: "RTR-1"}}

    assert {:ok, "Round 1 saved. The round is finished; end the turn with what it found."} =
             run_tool_save_review(task, %{"findings" => []}, [])

    assert {:ok, "Round 2 saved." <> _rest} = run_tool_save_review(task, %{}, [])
    assert [%{round: 1}, %{round: 2}] = Pipeline.read_review(task)
  end

  test "past Review a save is refused with where the task is, for the agent to answer in the conversation" do
    scratch = Path.join(System.tmp_dir!(), "rt_save_review_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{scratch_path: scratch, worktree_path: Path.join(scratch, "worktree"), issue: %Issue{identifier: "RTR-2"}}

    assert {:refused, "Nothing saved: the review is finished and the task is at Finalize" <> rest} =
             run_tool_save_review(%{task | stage: :finalize}, %{}, [])

    assert rest =~ "in the conversation"

    assert {:refused, "Nothing saved: the review is finished and the task has merged" <> _rest} =
             run_tool_save_review(%{task | stage: :merged}, %{}, [])

    assert [] = Pipeline.read_review(task)
  end
end
