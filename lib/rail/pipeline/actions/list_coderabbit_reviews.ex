defmodule Rail.Pipeline.Actions.ListCoderabbitReviews do
  @moduledoc """
  Lists the CodeRabbit reviews asked for on a task, which the task page counts against the hourly allowance.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Returns `task`'s CodeRabbit reviews, oldest first, each with who asked for it."
  def list_coderabbit_reviews(%Task{} = task) do
    Repo.all(
      from r in CoderabbitReview,
        where: r.task_id == ^task.id and r.project_id == ^task.project_id,
        order_by: [asc: r.inserted_at],
        preload: :requested_by
    )
  end
end
