defmodule Rail.Pipeline.Workers.CheckBases do
  @moduledoc """
  Checks every task under review or ready to merge against its default branch, a few minutes after
  `Rail.Git.Workers.FetchDefaultBranches` has fetched it, so a branch the default branch has moved past, or one
  that would conflict with it, shows Update without anyone looking.
  """
  use Oban.Worker, queue: :git, max_attempts: 1, unique: [period: 895]

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tasks = Repo.all(from t in Task, where: t.stage in [:review, :finalize] and is_nil(t.cleaned_up_at))
    for task <- tasks, do: {:ok, _checked} = Pipeline.check_base(task)
    :ok
  end
end
