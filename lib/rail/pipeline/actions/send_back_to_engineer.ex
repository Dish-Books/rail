defmodule Rail.Pipeline.Actions.SendBackToEngineer do
  @moduledoc """
  Sends a change back to the engineer on human request.

  This is the human overruling the rework budget: a fresh round is granted, every
  finding the change is still carrying is collected into one note for the
  engineer, and the engineer stage is entered again. A stage that is still working
  is left alone — there is nothing to send back until it stops.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CarriedReports
  import Rail.Pipeline.Utils.StageRun

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  @stages_before_engineer [:product, :design, :architect]

  @doc """
  Sends `task` back to the engineer with everything it is still carrying.
  """
  def send_back_to_engineer(task, opts \\ [])

  def send_back_to_engineer(%Task{stage: stage}, _opts) when stage in @stages_before_engineer do
    {:error, :stage_before_engineer}
  end

  def send_back_to_engineer(%Task{stage: :merged}, _opts) do
    {:error, :task_merged}
  end

  def send_back_to_engineer(%Task{} = task, opts) do
    if task |> stage_run() |> Run.running?() do
      {:error, :stage_running}
    else
      resolve_engineer(task, opts)
    end
  end

  defp resolve_engineer(%Task{} = task, opts) do
    case Roles.get_role(project_id: task.project_id, stage: :engineer) do
      {:ok, %Role{} = engineer_role} -> execute_send_back(task, engineer_role, opts)
      _no_role -> {:error, :no_engineer_role}
    end
  end

  defp execute_send_back(%Task{} = task, %Role{} = engineer_role, opts) do
    case resumable_engineer_run(task.id, engineer_role.id) do
      %Run{} = engineer_run -> apply_send_back(task, engineer_run, opts)
      nil -> {:error, :no_session}
    end
  end

  defp apply_send_back(%Task{} = task, %Run{} = engineer_run, opts) do
    note = extract_note(opts)
    carried = carried_reports(task)
    message = build_engineer_message(note, carried)

    Runs.append_pending_answer(engineer_run, message)

    attrs = %{
      rework_budget_base: task.rework_cycles || 0,
      rework_cycles_by_gate: %{},
      outstanding_reports: []
    }

    {:ok, task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    {:ok, _run} = Pipeline.enter_stage(task, :engineer, opts)
    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :sent_back_to_engineer})

    {:ok, Repo.reload!(task)}
  end

  defp extract_note(opts) when is_binary(opts), do: String.trim(opts)

  defp extract_note(opts) when is_list(opts) do
    case Keyword.get(opts, :comment) || Keyword.get(opts, :note) do
      str when is_binary(str) -> String.trim(str)
      _other -> ""
    end
  end

  defp extract_note(_other), do: ""

  defp build_engineer_message(note, carried) do
    base =
      "Sent back to you by the human, with the findings this change is still carrying. " <>
        "Address every one of them - nits included, and the ones marked pre-existing too - " <>
        "in the same worktree on the same branch, run the project's checks from the top, " <>
        "push to the existing pull request, and say what changed. " <>
        "Where you disagree with a finding, say why rather than silently leaving it."

    parts =
      [base] ++
        if(note == "", do: [], else: ["\n\nWhat the human asked for:\n\n#{note}"]) ++
        if carried == "", do: [], else: [carried]

    Enum.join(parts, "")
  end

  defp resumable_engineer_run(task_id, role_id) do
    case Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_id) do
      %Run{} = run -> if Run.resumable?(run), do: run
      nil -> nil
    end
  end
end
