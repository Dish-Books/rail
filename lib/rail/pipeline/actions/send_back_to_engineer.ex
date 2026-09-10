defmodule Rail.Pipeline.Actions.SendBackToEngineer do
  @moduledoc """
  Action to send a task back to the Engineer stage on human request.
  Resets the rework budget allowance (granting a fresh budget round), formats
  any human note alongside all outstanding gate reports, and re-queues the engineer.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CarriedReports, only: [build_carried_gate_reports: 1]

  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @stages_before_engineer [:product, :design, :architect]

  @doc """
  Sends a task back to the Engineer:
  - Enforces `stage_state != :running`, `stage not in [:product, :design, :architect]`, and `stage != :merged`.
  - Grants a fresh rework budget (`rework_budget_base = rework_cycles`, `rework_cycles_by_gate: %{}`).
  - Collects all gate reports listed in `outstanding_reports` and clears the list.
  - Populates the engineer role's `pending_answer` with human comment, instructions, and reports.
  - Sets `stage = :engineer`, `stage_state = :queued`, clears `error` and `retry_after`.
  - Broadcasts `pipeline_changed` and pumps the Dispatcher.
  """
  def send_back_to_engineer(%Scope{} = scope, task_or_id, opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_send_back_to_engineer(task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def send_back_to_engineer(%Scope{} = scope, task_or_id) do
    send_back_to_engineer(scope, task_or_id, [])
  end

  def send_back_to_engineer(task_or_id, opts) do
    send_back_to_engineer(Scope.for_system(), task_or_id, opts)
  end

  def send_back_to_engineer(task_or_id) do
    send_back_to_engineer(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_send_back_to_engineer(%Task{stage_state: :running}, _opts) do
    {:error, :task_running}
  end

  defp do_send_back_to_engineer(%Task{stage: stage}, _opts) when stage in @stages_before_engineer do
    {:error, :stage_before_engineer}
  end

  defp do_send_back_to_engineer(%Task{stage: :merged}, _opts) do
    {:error, :task_merged}
  end

  defp do_send_back_to_engineer(%Task{} = task, opts) do
    case Roles.role_for_stage(task.project_id, :engineer) do
      {:ok, %Role{} = engineer_role} ->
        execute_send_back(task, engineer_role, opts)

      _no_role ->
        {:error, :no_engineer_role}
    end
  end

  defp execute_send_back(%Task{} = task, %Role{} = engineer_role, opts) do
    note = extract_note(opts)
    carried_reports = build_carried_gate_reports(task)
    message = build_engineer_message(note, carried_reports)

    update_or_create_engineer_run(task.id, engineer_role.id, message)

    attrs = %{
      stage: :engineer,
      stage_state: :queued,
      rework_budget_base: task.rework_cycles || 0,
      rework_cycles_by_gate: %{},
      outstanding_reports: [],
      error: nil,
      retry_after: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :sent_back_to_engineer})
    Dispatcher.pump()

    {:ok, updated_task}
  end

  defp extract_note(opts) when is_binary(opts), do: String.trim(opts)

  defp extract_note(opts) when is_list(opts) do
    case Keyword.get(opts, :comment) || Keyword.get(opts, :note) do
      str when is_binary(str) -> String.trim(str)
      _other -> ""
    end
  end

  defp extract_note(_other), do: ""

  defp build_engineer_message(note, carried_reports) do
    base =
      "Sent back to you by the human, with the findings this change is still carrying. " <>
        "Address every one of them - nits included, and the ones marked pre-existing too - " <>
        "in the same worktree on the same branch, run the project's checks from the top, " <>
        "push to the existing pull request, and say what changed. " <>
        "Where you disagree with a finding, say why rather than silently leaving it."

    parts =
      [base] ++
        if(note == "", do: [], else: ["\n\nWhat the human asked for:\n\n#{note}"]) ++
        if carried_reports == "", do: [], else: [carried_reports]

    Enum.join(parts, "")
  end

  defp update_or_create_engineer_run(task_id, role_id, message) do
    case Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_id) do
      %RoleRun{} = existing ->
        pending = existing.pending_answer
        new_pending = if pending && String.trim(pending) != "", do: "#{pending}\n\n#{message}", else: message

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
          pending_answer: message,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()
    end
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
