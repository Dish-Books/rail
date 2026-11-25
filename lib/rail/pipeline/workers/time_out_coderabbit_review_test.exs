defmodule Rail.Pipeline.Workers.TimeOutCoderabbitReviewTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Pipeline
  alias Rail.Pipeline.Workers.TimeOutCoderabbitReview

  test "times the review out" do
    expect(Pipeline, :time_out_coderabbit_review, fn "crv_late" -> {:ok, :already_finished} end)
    assert :ok = perform_job(TimeOutCoderabbitReview, %{review_id: "crv_late"})
  end
end
