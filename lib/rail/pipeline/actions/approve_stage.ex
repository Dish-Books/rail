defmodule Rail.Pipeline.Actions.ApproveStage do
  @moduledoc """
  Approves a task waiting at an approval gate and advances it to the next pipeline stage.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.PrepareScratch

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @doc """
  Approves the current stage of a task:
  - Enforces `stage_state == :awaiting_approval` and `stage != :ready_to_merge`.
  - Determines the next stage in pipeline order (respecting `:skip_design`).
  - At `:product`, moves to `:design` if a `:design` role exists, skips to `:architect` if `:skip_design`,
    or parks at `:design` with an error if no `:design` role is configured.
  - At `:design`, requires a linked issue and picked direction, publishes the design comment to Linear,
    prepares architect scratch context, and advances to `:architect`.
  - Sets `stage_state: :queued` (or `:awaiting_approval` if advancing to `:ready_to_merge`).
  - Clears `error` and `retry_after`.
  - Broadcasts `pipeline_changed` and pumps the Dispatcher when queued.
  """
  def approve_stage(%Scope{} = scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_approve_stage(scope, task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def approve_stage(%Scope{} = scope, task_or_id) do
    approve_stage(scope, task_or_id, [])
  end

  def approve_stage(task_or_id, opts) when is_list(opts) do
    approve_stage(Scope.for_system(), task_or_id, opts)
  end

  def approve_stage(task_or_id) do
    approve_stage(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_approve_stage(_scope, %Task{stage_state: state}, _opts) when state != :awaiting_approval do
    {:error, {:invalid_stage_state, state}}
  end

  defp do_approve_stage(_scope, %Task{stage: :ready_to_merge}, _opts) do
    {:error, :cannot_approve_ready_to_merge}
  end

  defp do_approve_stage(_scope, %Task{stage: :product} = task, opts) do
    if Keyword.get(opts, :skip_design, false) do
      advance_stage(task, :architect, opts)
    else
      advance_stage(task, :design, opts)
    end
  end

  defp do_approve_stage(scope, %Task{stage: :design} = task, opts) do
    with {:ok, issue} <- validate_linked_issue(task),
         {:ok, design, direction} <- validate_design_and_direction(task),
         :ok <- publish_design_comment(scope, task, issue, design, direction) do
      scratch_dir = Keyword.get(opts, :scratch_dir)
      if scratch_dir, do: prepare_scratch(task, scratch_dir)
      advance_stage(task, :architect, opts)
    end
  end

  defp do_approve_stage(_scope, %Task{} = task, opts) do
    next_stage = determine_next_stage(task, opts)
    advance_stage(task, next_stage, opts)
  end

  defp validate_linked_issue(%Task{issue_id: nil} = task) do
    set_task_error(task, "This task has no GitHub issue, so the design cannot be published.", :no_issue)
  end

  defp validate_linked_issue(%Task{issue_id: issue_id} = task) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue ->
        {:ok, issue}

      nil ->
        set_task_error(task, "This task has no GitHub issue, so the design cannot be published.", :no_issue)
    end
  end

  defp validate_design_and_direction(%Task{} = task) do
    case Repo.one(from d in Design, where: d.task_id == ^task.id, order_by: [desc: d.version], limit: 1) do
      %Design{} = design ->
        case resolve_picked_direction(design) do
          dir when is_map(dir) ->
            {:ok, design, dir}

          nil ->
            set_task_error(task, "No design direction has been picked to publish.", :no_picked_direction)
        end

      nil ->
        set_task_error(task, "No design artifact found to publish.", :no_design)
    end
  end

  defp resolve_picked_direction(%Design{picked_key: key, directions: directions}) when is_binary(key) and key != "" do
    Enum.find(directions || [], fn d -> d.key == key end)
  end

  defp resolve_picked_direction(%Design{directions: [single]}) do
    single
  end

  defp resolve_picked_direction(_other), do: nil

  defp publish_design_comment(scope, task, issue, design, direction) do
    comment_body =
      "## Design: #{direction.title}\n\n#{direction.notes}\n\n" <>
        "![#{direction.title}](#{direction.still_url})\n\n" <>
        "[View live canvas](#{design.canvas_url})\n"

    owner_user = issue.owner_user_id && %{id: issue.owner_user_id}

    case Issues.comment(scope, issue, comment_body, owner_user) do
      {:ok, _comment} ->
        :ok

      {:error, err} ->
        err_str = if is_binary(err), do: err, else: inspect(err)
        msg = "Failed to publish design: #{err_str}"
        set_task_error(task, msg, {:publish_failed, msg})
    end
  end

  defp set_task_error(task, error_msg, return_err) do
    {:ok, _updated_task} =
      task
      |> Task.changeset(%{error: error_msg})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :stage_approved})
    {:error, return_err}
  end

  defp advance_stage(%Task{} = task, next_stage, _opts) do
    {stage_state, error} =
      if next_stage == :ready_to_merge do
        {:awaiting_approval, nil}
      else
        case Roles.get_role(project_id: task.project_id, stage: next_stage) do
          {:ok, _role} ->
            {:queued, nil}

          _no_role ->
            {:failed,
             "No role \"#{next_stage}\" is configured, so the #{next_stage} stage has nothing to run it. Add it under Settings, then retry this stage."}
        end
      end

    attrs = %{
      stage: next_stage,
      stage_state: stage_state,
      retry_after: nil,
      error: error
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :stage_approved})

    if stage_state == :queued do
      Dispatcher.pump()
    end

    {:ok, updated_task}
  end

  defp determine_next_stage(%Task{stage: :architect}, _opts), do: :engineer
  defp determine_next_stage(%Task{stage: :engineer}, _opts), do: :review
  defp determine_next_stage(%Task{stage: :review}, _opts), do: :qa
  defp determine_next_stage(%Task{stage: :qa}, _opts), do: :qa_lead

  defp determine_next_stage(%Task{stage: :qa_lead} = task, _opts) do
    case Roles.get_role(project_id: task.project_id, stage: :demo) do
      {:ok, _role} -> :demo
      _no_role -> :ready_to_merge
    end
  end

  defp determine_next_stage(%Task{stage: :demo}, _opts), do: :ready_to_merge
  defp determine_next_stage(_other, _opts), do: :ready_to_merge

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
