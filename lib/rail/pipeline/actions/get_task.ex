defmodule Rail.Pipeline.Actions.GetTask do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Gets a single task by ID, with its project, issue and artifacts loaded.
  """
  def get_task(id) when is_binary(id) do
    query = from(t in Task, where: t.id == ^id, preload: [:project, :issue, :plans, :runs, :designs, :demos])

    case Repo.one(query) do
      %Task{} = task -> {:ok, attach_latest_artifacts(task)}
      nil -> {:error, :not_found}
    end
  end

  defp attach_latest_artifacts(%Task{} = task) do
    latest_demo =
      if is_list(task.demos) and task.demos != [] do
        Enum.max_by(task.demos, & &1.version)
      end

    latest_design =
      if is_list(task.designs) and task.designs != [] do
        Enum.max_by(task.designs, & &1.version)
      end

    %{task | demo: latest_demo, design: latest_design}
  end
end
