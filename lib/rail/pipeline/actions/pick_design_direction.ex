defmodule Rail.Pipeline.Actions.PickDesignDirection do
  @moduledoc """
  Action to pick a design direction for a task at the design stage.
  Updates the picked_key on the latest design record, generates a pick brief,
  and requests changes from the designer to narrow down the design.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.Briefs

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Picks a design direction for a task:
  - Requires task stage to be `:design`.
  - Finds the latest design record and verifies the specified key exists in its directions.
  - Updates `picked_key` on the design record.
  - Generates the pick brief with `Briefs.design_pick_brief/2`.
  - Delegates to `RequestChanges.request_changes/4` with `is_pick: true`.
  """
  def pick_design_direction(%Scope{} = scope, task_or_id, key, opts) when is_binary(key) and is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id),
         :ok <- validate_stage(task),
         {:ok, design} <- get_latest_design(task.id),
         {:ok, direction} <- find_direction(design, key) do
      do_pick_design_direction(scope, task, design, direction, key, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def pick_design_direction(%Scope{} = scope, task_or_id, key) when is_binary(key) do
    pick_design_direction(scope, task_or_id, key, [])
  end

  def pick_design_direction(task_or_id, key, opts) when is_binary(key) and is_list(opts) do
    pick_design_direction(Scope.for_system(), task_or_id, key, opts)
  end

  def pick_design_direction(task_or_id, key) when is_binary(key) do
    pick_design_direction(Scope.for_system(), task_or_id, key, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp validate_stage(%Task{stage: :design}), do: :ok
  defp validate_stage(%Task{stage: other_stage}), do: {:error, {:invalid_stage, other_stage}}

  defp get_latest_design(task_id) do
    case Repo.one(from d in Design, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1) do
      %Design{} = design -> {:ok, design}
      nil -> {:error, :design_not_found}
    end
  end

  defp find_direction(%Design{directions: directions}, key) do
    case Enum.find(directions || [], fn %DesignDirection{key: k} -> k == key end) do
      %DesignDirection{} = dir -> {:ok, dir}
      nil -> {:error, {:direction_not_found, key}}
    end
  end

  defp do_pick_design_direction(scope, %Task{} = task, %Design{} = design, %DesignDirection{} = direction, key, opts) do
    {:ok, updated_design} =
      design
      |> Design.changeset(%{picked_key: key})
      |> Repo.update()

    pick_brief = design_pick_brief(key, title: direction.title, design: updated_design)
    request_opts = opts |> Keyword.put(:stage, :design) |> Keyword.put(:is_pick, true)

    Pipeline.request_changes(scope, task, pick_brief, request_opts)
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
