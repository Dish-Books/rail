defmodule Rail.Pipeline.Workers.CheckPreviews do
  @moduledoc """
  Looks at the preview of every task with a pull request at Review or Finalize, once a minute, so the App item
  follows each push to its deployment without anyone reloading.
  """
  use Oban.Worker, queue: :previews, max_attempts: 1, unique: [period: 50]

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tasks =
      Repo.all(
        from t in Task,
          join: p in Project,
          on: p.id == t.project_id,
          where: p.preview_enabled and not is_nil(t.pr_number) and is_nil(t.cleaned_up_at),
          where: t.stage in [:review, :finalize]
      )

    for task <- tasks, do: {:ok, _preview} = Pipeline.check_preview(task)
    :ok
  end
end
