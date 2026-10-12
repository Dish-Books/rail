defmodule Rail.Pipeline.Utils.ReopenReviewRun do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @running [:starting, :running, :waiting_for_resources, :waiting_for_usage]

  @doc """
  Moves the Review `run` to running with `note` as what its next turn is sent, unless it already works. Only one of
  two callers racing for it gets `{1, [run]}`; the other gets `{0, []}`.
  """
  def reopen_review_run(%Run{id: id}, note) do
    Repo.update_all(
      from(r in Run, where: r.id == ^id and r.status not in ^@running, select: r),
      set: [
        status: :running,
        stage_outcome: :in_progress,
        error: nil,
        ci_failure_streak: 0,
        completed_at: nil,
        pending_answer: note,
        updated_at: DateTime.utc_now()
      ]
    )
  end
end
