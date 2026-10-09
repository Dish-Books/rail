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

  test "each finished pass reads with its round, time, the commit it read and when the review finished", %{
    task: task,
    path: path
  } do
    File.write!(
      path,
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-04T12:00:00Z", "head": "abc", "finished_at": null},) <>
        ~s({"round": 2, "saved_at": "2026-10-05T12:00:00Z", "head": null, "finished_at": "2026-10-05T13:00:00Z"}]})
    )

    assert [
             %{round: 1, saved_at: ~U[2026-10-04 12:00:00Z], head: "abc", finished_at: nil},
             %{round: 2, saved_at: ~U[2026-10-05 12:00:00Z], head: nil, finished_at: ~U[2026-10-05 13:00:00Z]}
           ] = Pipeline.read_review(task)
  end

  # An agent still holding the old brief could write the old shape after the deploy;
  # reading that as a finished pass would close a round nobody finished.
  test "the old one-pass shape, or a report an agent wrote, is no pass at all", %{task: task, path: path} do
    File.write!(path, ~s({"saved_at": "2026-10-04T12:00:00Z"}))
    assert Pipeline.read_review(task) == []

    File.write!(path, ~s({"findings": [{"key": "k", "title": "t"}]}))
    assert Pipeline.read_review(task) == []

    File.write!(path, ~s({"passes": []}))
    assert Pipeline.read_review(task) == []
  end

  test "a pass that is not a pass makes the whole file unread", %{task: task, path: path} do
    File.write!(path, ~s({"passes": [{"round": 1, "saved_at": "yesterday"}]}))
    assert Pipeline.read_review(task) == []

    File.write!(path, ~s({"passes": [{"round": "one", "saved_at": "2026-10-04T12:00:00Z"}]}))
    assert Pipeline.read_review(task) == []
  end

  test "a finished time that is not a time reads as not finished", %{task: task, path: path} do
    File.write!(path, ~s({"passes": [{"round": 1, "saved_at": "2026-10-04T12:00:00Z", "finished_at": "soon"}]}))

    assert [%{round: 1, finished_at: nil, head: nil}] = Pipeline.read_review(task)
  end

  test "a missing or unreadable file reads as no pass", %{task: task, path: path} do
    assert Pipeline.read_review(task) == []

    File.write!(path, "Looks fine to me.")
    assert Pipeline.read_review(task) == []
  end
end
