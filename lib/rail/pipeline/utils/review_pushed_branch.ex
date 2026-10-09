defmodule Rail.Pipeline.Utils.ReviewPushedBranch do
  @moduledoc """
  What a pushed commit asks for once it is up: the engineer's goes to Review, and a commit on the Review
  lead's run, its fixes or a merge of the default branch, starts the lead's next round.
  """

  import Rail.Pipeline.Utils.StartNextRound

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Reviews `run`'s pushed branch, saying in a next round's conversation that it started `after_what`.
  Returns `{:ok, run}` as it now stands, or `{:error, reason}`.
  """
  def review_pushed_branch(%Run{role: %Role{stage: :review_lead}} = run, after_what) do
    with :ok <- start_next_round(run, after_what) do
      {:ok, %{Repo.get!(Run, run.id) | task: run.task, role: run.role}}
    end
  end

  def review_pushed_branch(%Run{} = run, _after_what), do: Pipeline.send_to_review(run)
end
