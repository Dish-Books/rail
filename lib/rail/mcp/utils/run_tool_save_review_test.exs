defmodule Rail.Mcp.Utils.RunToolSaveReviewTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveReview

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "closing the pass is receipted, whatever arrived with it" do
    scratch = Path.join(System.tmp_dir!(), "rt_save_review_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{scratch_path: scratch, issue: %Issue{identifier: "RTR-1"}}

    assert {:ok, "Review saved. The pass is finished."} = run_tool_save_review(task, %{"findings" => []}, [])
    assert %DateTime{} = Pipeline.read_review(task)
  end
end
