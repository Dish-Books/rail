defmodule Rail.Pipeline.Actions.RequestChanges do
  @moduledoc """
  Action to request changes from a pipeline role with a human comment.
  Appends the comment to the target role's `pending_answer`, resets auto-retries,
  re-queues the stage, and pumps the dispatcher.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.Briefs

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @stages_before_engineer [:product, :design, :architect]

  @doc """
  Requests changes on a task:
  - Requires a non-empty trimmed comment.
  - Resolves target stage (defaults to current task stage).
  - If target stage owns no role (`ready_to_merge`) and stage is at/after engineer,
    delegates to `SendBackToEngineer`.
  - Sets `stage_state: :queued`, clears `error` and `retry_after`.
  - Appends comment to target role run's `pending_answer` and resets `auto_retries = 0`.
  - Broadcasts `pipeline_changed` and pumps the Dispatcher.
  """
  def request_changes(%Scope{} = scope, task_or_id, comment, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id),
         {:ok, trimmed_comment} <- validate_comment(comment) do
      do_request_changes(scope, task, trimmed_comment, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def request_changes(%Scope{} = scope, task_or_id, comment) do
    request_changes(scope, task_or_id, comment, [])
  end

  def request_changes(task_or_id, comment, opts) when is_list(opts) do
    request_changes(Scope.for_system(), task_or_id, comment, opts)
  end

  def request_changes(task_or_id, comment) do
    request_changes(Scope.for_system(), task_or_id, comment, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp validate_comment(comment) when is_binary(comment) do
    trimmed = String.trim(comment)
    if trimmed == "", do: {:error, :empty_comment}, else: {:ok, trimmed}
  end

  defp validate_comment(_other), do: {:error, :empty_comment}

  defp do_request_changes(scope, %Task{} = task, comment, opts) do
    target_stage = Keyword.get(opts, :stage) || task.stage

    if target_stage == :ready_to_merge do
      if target_stage in @stages_before_engineer do
        {:error, {:no_role_for_stage, target_stage}}
      else
        Pipeline.send_back_to_engineer(scope, task, comment: comment)
      end
    else
      resolve_and_apply_changes(task, target_stage, comment, opts)
    end
  end

  defp resolve_and_apply_changes(%Task{} = task, target_stage, comment, opts) do
    stage_for_role = if task.is_rebasing, do: :engineer, else: target_stage

    case Roles.role_for_stage(task.project_id, stage_for_role) do
      {:ok, %Role{} = target_role} ->
        formatted_comment = format_comment_for_stage(task, target_stage, comment, opts)
        update_task_and_role_run(task, target_stage, target_role, formatted_comment, comment)

      _no_role ->
        {:error, {:no_role_for_stage, stage_for_role}}
    end
  end

  defp format_comment_for_stage(%Task{} = task, :design, comment, opts) do
    if Keyword.get(opts, :is_pick, false) do
      comment
    else
      case Repo.one(from d in Design, where: d.task_id == ^task.id, order_by: [desc: d.version], limit: 1) do
        %Design{picked_key: picked_key} when is_binary(picked_key) and picked_key != "" ->
          design_revise_brief(comment)

        _other ->
          comment
      end
    end
  end

  defp format_comment_for_stage(_task, _stage, comment, _opts), do: comment

  defp update_task_and_role_run(%Task{} = task, target_stage, %Role{} = target_role, comment, raw_comment) do
    update_role_run_pending_answer(task.id, target_role.id, comment, raw_comment)

    new_stage = if task.is_rebasing, do: task.stage, else: target_stage

    attrs = %{
      stage: new_stage,
      stage_state: :queued,
      error: nil,
      retry_after: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :changes_requested})
    Dispatcher.pump()

    {:ok, updated_task}
  end

  defp update_role_run_pending_answer(task_id, role_id, comment, raw_comment) do
    role_run =
      case Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_id) do
        %RoleRun{} = existing ->
          pending = existing.pending_answer
          new_pending = if pending && String.trim(pending) != "", do: "#{pending}\n\n#{comment}", else: comment

          existing
          |> RoleRun.changeset(%{pending_answer: new_pending, auto_retries: 0})
          |> Repo.update!()

        nil ->
          %RoleRun{}
          |> RoleRun.changeset(%{
            task_id: task_id,
            role_id: role_id,
            status: :finished,
            auto_retries: 0,
            pending_answer: comment,
            started_at: DateTime.utc_now()
          })
          |> Repo.insert!()
      end

    Runs.append_run_event(role_run.id, "[human] #{raw_comment}")
    role_run
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
