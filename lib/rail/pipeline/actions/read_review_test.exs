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

  # Written by the agent before Rail took the file over, so it says nothing of
  # when; the file's own time stands in.
  test "a report written before this change still counts as closed", %{task: task, path: path} do
    File.write!(path, ~s({"findings": [{"key": "k", "title": "t"}]}))
    File.touch!(path, 1_790_000_000)

    assert Pipeline.read_review(task) == ~U[2026-09-21 14:13:20Z]
  end

  test "a saved time that is not a time falls back to the file's", %{task: task, path: path} do
    File.write!(path, ~s({"saved_at": "yesterday"}))
    File.touch!(path, 1_790_000_000)

    assert Pipeline.read_review(task) == ~U[2026-09-21 14:13:20Z]
  end

  test "a missing or unreadable file reads as not closed", %{task: task, path: path} do
    assert Pipeline.read_review(task) == nil

    File.write!(path, "Looks fine to me.")
    assert Pipeline.read_review(task) == nil
  end
end
