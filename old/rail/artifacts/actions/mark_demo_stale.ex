defmodule Rail.Artifacts.Actions.MarkDemoStale do
  @moduledoc false

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Repo

  def mark_demo_stale(_scope, target, _opts \\ []) do
    task_id = extract_task_id(target)
    do_mark_demo_stale(task_id)
  end

  defp extract_task_id(%{id: task_id}), do: to_string(task_id)
  defp extract_task_id(task_id) when is_binary(task_id), do: task_id
  defp extract_task_id(other), do: to_string(other)

  defp do_mark_demo_stale(task_id) do
    query =
      from d in Demo,
        where: d.task_id == ^task_id,
        order_by: [desc: d.version],
        limit: 1

    case Repo.one(query) do
      %Demo{} = latest_demo ->
        latest_demo
        |> Demo.changeset(%{stale: true})
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end
end
