defmodule Rail.Pipeline.Schemas.CoderabbitReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.CoderabbitReview

  test "a review waits while asked or reviewing, and every status past that says how it ended" do
    labels = [
      requested: {true, "Asked"},
      reviewing: {true, "Reviewing"},
      done: {false, "Done"},
      skipped: {false, "Skipped by CodeRabbit"},
      rate_limited: {false, "Rate limited"},
      failed: {false, "Failed"},
      timed_out: {false, "No answer"}
    ]

    for {status, {pending, label}} <- labels do
      review = %CoderabbitReview{status: status}
      assert CoderabbitReview.pending?(review) == pending
      assert CoderabbitReview.status_label(review) == label
    end
  end

  test "moving past reviewing stamps when it ended, and moving back to waiting clears it" do
    assert %{changes: %{status: :done, finished_at: %DateTime{}, comment_count: 2}} =
             CoderabbitReview.status_changeset(%CoderabbitReview{status: :reviewing}, :done, %{comment_count: 2})

    assert %{changes: %{status: :reviewing}} =
             changeset = CoderabbitReview.status_changeset(%CoderabbitReview{status: :requested}, :reviewing)

    assert Ecto.Changeset.get_field(changeset, :finished_at) == nil
  end
end
