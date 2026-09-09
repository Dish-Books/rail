defmodule Rail.Pipeline.Queue do
  @moduledoc """
  Queue ordering and dispatch decision logic for agent roles in the pipeline.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Calculates how many concurrent runs are currently live for a role in a project.
  A task occupies a role's concurrency slot if:
  - It is currently active in a chat turn with this role (`active_chat_role_id == role.id`).
  - Its stage state is `:running` and either:
    - It is rebasing and the role is bound to the engineer stage (rebase role).
    - It is not rebasing and its stage matches the role's stage.
  """
  def current_live_runs_count(project_or_id, %Role{} = role) do
    project_id = extract_project_id(project_or_id)
    role_id = role.id

    base_query =
      from t in Task,
        where: t.project_id == ^project_id

    query =
      case role.stage do
        :engineer ->
          from t in base_query,
            where:
              (t.stage_state == :running and (t.is_rebasing == true or t.stage == :engineer)) or
                (not is_nil(t.active_chat_role_id) and t.active_chat_role_id == ^role_id)

        stage when is_atom(stage) and stage != nil ->
          from t in base_query,
            where:
              (t.stage_state == :running and t.is_rebasing == false and t.stage == ^stage) or
                (not is_nil(t.active_chat_role_id) and t.active_chat_role_id == ^role_id)

        nil ->
          from t in base_query,
            where: not is_nil(t.active_chat_role_id) and t.active_chat_role_id == ^role_id
      end

    Repo.aggregate(query, :count, :id)
  end

  @doc """
  Calculates available concurrency slots for a role in a project:
  `max(0, role.max_concurrent - current_live_runs_count)`.
  """
  def available_slots(project_or_id, %Role{} = role) do
    live_count = current_live_runs_count(project_or_id, role)
    max(0, role.max_concurrent - live_count)
  end

  @doc """
  Returns a list of queued tasks eligible for dispatch under the specified role,
  up to the number of available concurrency slots.
  Tasks are filtered by:
  - Matching the project.
  - Stage matches role stage (or `is_rebasing: true` when role stage is `:engineer`).
  - `stage_state: :queued`.
  - Not waiting on retry backoff (`retry_after == nil || retry_after <= DateTime.utc_now()`).
  - Ordered by `inserted_at: :asc` (FIFO arrival order).
  """
  def eligible_tasks(_project_or_id, %Role{stage: nil}), do: []

  def eligible_tasks(project_or_id, %Role{} = role) do
    slots = available_slots(project_or_id, role)

    if slots > 0 do
      fetch_eligible_tasks(extract_project_id(project_or_id), role.stage, slots)
    else
      []
    end
  end

  defp fetch_eligible_tasks(project_id, role_stage, slots) do
    now = DateTime.utc_now()

    base_query =
      from t in Task,
        where: t.project_id == ^project_id,
        where: t.stage_state == :queued,
        where: is_nil(t.retry_after) or t.retry_after <= ^now,
        order_by: [asc: t.inserted_at],
        limit: ^slots

    query =
      if role_stage == :engineer do
        from t in base_query,
          where: t.is_rebasing == true or t.stage == :engineer
      else
        from t in base_query,
          where: t.is_rebasing == false and t.stage == ^role_stage
      end

    Repo.all(query)
  end

  defp extract_project_id(%Project{id: id}), do: id
  defp extract_project_id(id) when is_binary(id), do: id
end
