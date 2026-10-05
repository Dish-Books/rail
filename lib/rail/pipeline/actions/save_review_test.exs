defmodule Rail.Pipeline.Actions.SaveReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "closing a review writes the file read_review finds, saying when" do
    scratch = Path.join(System.tmp_dir!(), "save_review_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{scratch_path: scratch, issue: %Issue{identifier: "SVR-1"}}

    assert Pipeline.read_review(task) == nil
    assert {:ok, %DateTime{} = saved_at} = Pipeline.save_review(task)
    assert ^saved_at = Pipeline.read_review(task)
  end
end
