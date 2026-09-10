defmodule Rail.Pipeline.Actions.RecheckDesign do
  @moduledoc """
  Action to re-evaluate the design manifest on disk without requiring a version bump.
  Allows landing a previously failed design stage once the canvas is published or fixes made.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.Scratch

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @doc """
  Re-checks the design manifest for a task:
  - If task stage is not :design, returns {:ok, task}.
  - If the designer is currently running, returns {:error, "The Designer is still running; wait for it to finish."}.
  - Reads and validates manifest without requiring an incremented version.
  - Checks that any previously chosen direction (`picked_key`) is preserved.
  - If valid:
    - Captures the design artifact.
    - Sets `stage_state: :awaiting_approval, error: nil`.
    - Logs success event on the designer's role run.
    - Broadcasts `pipeline_changed`.
    - Returns `{:ok, updated_task}`.
  - If invalid:
    - Sets `stage_state: :failed, error: reason`.
    - Logs turn-down event on the designer's role run.
    - Broadcasts `pipeline_changed`.
    - Returns `{:error, reason}`.
  """
  def recheck_design(%Scope{} = scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_recheck_design(scope, task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def recheck_design(%Scope{} = scope, task_or_id) do
    recheck_design(scope, task_or_id, [])
  end

  def recheck_design(task_or_id, opts) when is_list(opts) do
    recheck_design(Scope.for_system(), task_or_id, opts)
  end

  def recheck_design(task_or_id) do
    recheck_design(Scope.for_system(), task_or_id, [])
  end

  @doc """
  Reads, validates, and captures the design manifest for a task.
  Supports `require_new_version: true` (for clean run settlement) or `false` (for recheck / chat turns).
  """
  def apply_design_manifest(%Scope{} = scope, %Task{} = task, opts \\ []) do
    design_target = resolve_design_target(task, opts)
    read_opts = Keyword.take(opts, [:url_probe, :req_options])
    require_new_version = Keyword.get(opts, :require_new_version, false)
    project = Keyword.get(opts, :project) || (task.project_id && Repo.get(Project, task.project_id))

    capture_opts =
      opts
      |> Keyword.take([:issue, :owner_user, :url_probe, :req_options])
      |> Keyword.put(:project, project)

    previous_design =
      Repo.one(
        from d in Design,
          where: d.task_id == ^task.id,
          order_by: [desc: d.version],
          limit: 1
      )

    with {:ok, manifest_data} <- Artifacts.read_design(scope, design_target, read_opts),
         :ok <- validate_transition(manifest_data, previous_design, require_new_version),
         {:ok, design} <- Artifacts.capture_design(scope, task, design_target, capture_opts) do
      {:ok, design}
    else
      {:error, reason} ->
        err_msg = if is_binary(reason), do: reason, else: inspect(reason)
        {:error, err_msg}
    end
  end

  @doc """
  Returns a timestamp/size stamp of the design manifest on disk, or nil if none exists.
  """
  def design_manifest_stamp(%Task{worktree_path: path}), do: design_manifest_stamp(path)

  def design_manifest_stamp(worktree_path) when is_binary(worktree_path) do
    manifest_path =
      cond do
        File.exists?(Path.join(worktree_path, ".axis/design/manifest.json")) ->
          Path.join(worktree_path, ".axis/design/manifest.json")

        File.exists?(Path.join(worktree_path, "manifest.json")) ->
          Path.join(worktree_path, "manifest.json")

        true ->
          nil
      end

    with path when is_binary(path) <- manifest_path,
         {:ok, %File.Stat{mtime: mtime, size: size}} <- File.stat(path, time: :posix) do
      "#{mtime}:#{size}"
    else
      _other -> nil
    end
  end

  def design_manifest_stamp(_worktree), do: nil

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_recheck_design(_scope, %Task{stage: stage} = task, _opts) when stage != :design do
    {:ok, task}
  end

  defp do_recheck_design(scope, %Task{} = task, opts) do
    if task.stage_state == :running or Runs.running?(task.id) do
      {:error, "The Designer is still running; wait for it to finish."}
    else
      execute_recheck(scope, task, opts)
    end
  end

  defp execute_recheck(scope, task, opts) do
    apply_opts = Keyword.put(opts, :require_new_version, false)

    case apply_design_manifest(scope, task, apply_opts) do
      {:ok, %Design{} = design} ->
        {:ok, updated_task} =
          task
          |> Task.changeset(%{stage_state: :awaiting_approval, error: nil})
          |> Repo.update()

        log_designer_event(task, "[axis] Design re-checked: manifest v#{design.version} accepted.")
        Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :design_rechecked})
        {:ok, updated_task}

      {:error, reason} ->
        err_msg = if is_binary(reason), do: reason, else: inspect(reason)

        {:ok, updated_task} =
          task
          |> Task.changeset(%{stage_state: :failed, error: err_msg})
          |> Repo.update()

        log_designer_event(task, "[axis] Design re-check turned it down: #{err_msg}")
        Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :design_recheck_failed})
        {:error, err_msg}
    end
  end

  defp log_designer_event(task, line) do
    with {:ok, %Role{} = designer_role} <- Roles.role_for_stage(task.project_id, :design),
         %RoleRun{} = role_run <-
           Repo.one(
             from r in RoleRun,
               where: r.task_id == ^task.id and r.role_id == ^designer_role.id,
               order_by: [desc: r.inserted_at],
               limit: 1
           ) do
      Runs.append_run_event(role_run.id, line)
    else
      _other -> :ok
    end
  end

  defp resolve_design_target(task, opts) do
    cond do
      Keyword.get(opts, :scratch_dir) ->
        Keyword.get(opts, :scratch_dir)

      Keyword.get(opts, :scratch_path) ->
        Keyword.get(opts, :scratch_path)

      Keyword.get(opts, :worktree_path) ->
        Keyword.get(opts, :worktree_path)

      task.worktree_path && task.worktree_path != "" ->
        task.worktree_path

      true ->
        default_scratch_path(task.project_id, task.id)
    end
  end

  defp validate_transition(_manifest_data, nil, _require_new_version), do: :ok

  defp validate_transition(manifest_data, %Design{} = prev, require_new_version) do
    cond do
      prev.picked_key != nil and (is_nil(manifest_data.picked_key) or manifest_data.picked_key == "") ->
        {:error, "Design manifest is missing pickedKey (expected \"#{prev.picked_key}\")."}

      prev.picked_key != nil and manifest_data.picked_key != prev.picked_key ->
        {:error,
         "Design manifest pickedKey (#{manifest_data.picked_key}) does not match chosen direction (#{prev.picked_key})."}

      prev.picked_key != nil and not direction_present?(manifest_data.directions, prev.picked_key) ->
        {:error, "Manifest missing picked direction: #{prev.picked_key}"}

      require_new_version and manifest_data.version <= prev.version ->
        {:error, "Manifest version must be incremented after a pick or revision."}

      true ->
        :ok
    end
  end

  defp direction_present?(directions, key) when is_binary(key) do
    is_list(directions) and Enum.any?(directions, fn d -> Map.get(d, :key) == key end)
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
