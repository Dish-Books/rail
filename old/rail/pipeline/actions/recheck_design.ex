defmodule Rail.Pipeline.Actions.RecheckDesign do
  @moduledoc """
  Action to re-evaluate the design manifest on disk without requiring a version bump.
  Allows landing a previously failed design stage once the canvas is published or fixes made.
  """

  import Ecto.Query

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc """
  Re-checks the design manifest `run` wrote.

  The verdict is about that run's work, so it is recorded there: a manifest that
  reads cleanly latches the run done, and one that does not leaves it open with
  the reason, which is what a message to the designer then fixes.
  """
  def recheck_design(%Run{} = run, opts \\ []) do
    %Run{task: %Task{} = task} = run = Repo.preload(run, task: :runs)
    do_recheck_design(run, task, opts)
  end

  @doc """
  Reads, validates, and captures the design manifest for a task.
  Supports `require_new_version: true` (for clean run settlement) or `false` (for recheck / chat turns).
  """
  def apply_design_manifest(%Task{} = task, opts \\ []) do
    scope = Scope.for_system()
    design_target = task.scratch_path
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
  Returns a timestamp/size stamp of the design manifest in `scratch_path`, or nil.

  Used to tell whether a chat turn rewrote the manifest.
  """
  def design_manifest_stamp(%Task{scratch_path: path}), do: design_manifest_stamp(path)

  def design_manifest_stamp(scratch_path) when is_binary(scratch_path) do
    manifest_path = Path.join([scratch_path, "design", "manifest.json"])

    case File.stat(manifest_path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> "#{mtime}:#{size}"
      _other -> nil
    end
  end

  def design_manifest_stamp(_other), do: nil

  defp do_recheck_design(_run, %Task{stage: stage} = task, _opts) when stage != :design do
    {:ok, task}
  end

  defp do_recheck_design(%Run{} = run, %Task{} = task, opts) do
    if Task.running?(task) do
      {:error, "The Designer is still running; wait for it to finish."}
    else
      execute_recheck(run, task, opts)
    end
  end

  defp execute_recheck(%Run{} = run, %Task{} = task, opts) do
    apply_opts = Keyword.put(opts, :require_new_version, false)

    case apply_design_manifest(task, apply_opts) do
      {:ok, %Design{} = design} ->
        record_recheck(run, nil)
        Runs.append_run_event(run, "[rail] Design re-checked: manifest v#{design.version} accepted.")
        {:ok, task}

      {:error, reason} ->
        err_msg = if is_binary(reason), do: reason, else: inspect(reason)
        record_recheck(run, err_msg)
        Runs.append_run_event(run, "[rail] Design re-check turned it down: #{err_msg}")
        {:error, err_msg}
    end
  end

  defp record_recheck(%Run{} = run, error) do
    outcome = if error, do: :in_progress, else: :done
    run |> Run.changeset(%{error: error, stage_outcome: outcome}) |> Repo.update!()
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
end
