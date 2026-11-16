defmodule Rail.Pipeline.Actions.GetPreview do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "The deployment of `task`'s pull request as Rail last saw it, or nil before it was ever looked for."
  def get_preview(%Task{id: task_id}), do: Repo.get_by(Preview, task_id: task_id)
end
