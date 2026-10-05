defmodule Rail.Pipeline.Actions.ReadReviewTest do
  use ExUnit.Case, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "read_review_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch, "reviews"))
    on_exit(fn -> File.rm_rf(scratch) end)

    %{
      task: %Task{scratch_path: scratch, issue: %Issue{identifier: "RDR-1"}},
      path: Path.join([scratch, "reviews", "RDR-1.json"])
    }
  end

  test "a closed review reads as closed, at the time it was saved", %{task: task, path: path} do
    File.write!(path, ~s({"saved_at": "2026-10-04T12:00:00Z"}))

    assert Pipeline.read_review(task) == ~U[2026-10-04 12:00:00Z]
  end

  # An agent still holding the old brief writes its report here after the deploy;
  # reading that as closed would drop its findings and send the task on.
  test "a report in the old shape an agent wrote is not a closed review", %{task: task, path: path} do
    File.write!(path, ~s({"findings": [{"key": "k", "title": "t"}]}))
    assert Pipeline.read_review(task) == nil

    File.write!(path, ~s({"findings": []}))
    assert Pipeline.read_review(task) == nil
  end

  test "a saved time that is not a time is not a closed review", %{task: task, path: path} do
    File.write!(path, ~s({"saved_at": "yesterday"}))

    assert Pipeline.read_review(task) == nil
  end

  test "a missing or unreadable file reads as not closed", %{task: task, path: path} do
    assert Pipeline.read_review(task) == nil

    File.write!(path, "Looks fine to me.")
    assert Pipeline.read_review(task) == nil
  end
end
