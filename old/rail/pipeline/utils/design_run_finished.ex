defmodule Rail.Pipeline.Utils.DesignRunFinished do
  @moduledoc """
  Where a finished design run leaves its task.

  The designer reports through a manifest in the task's scratch directory. A
  revision has to keep the direction a human already picked and move the version
  forward; anything else is recorded as a failure on the run rather than quietly
  replacing the design that was chosen. A human picks or approves, and that is
  what enters the next stage.
  """

  import Ecto.Query

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc "Finishes `run` as the design stage."
  def design_run_finished(%Run{task: %Task{scratch_path: scratch_dir} = task} = run, opts) do
    scope = Scope.for_system()
    read_opts = Keyword.take(opts, [:url_probe, :req_options])
    capture_opts = Keyword.take(opts, [:project, :issue, :owner_user, :url_probe, :req_options])

    with {:ok, manifest} <- Artifacts.read_design(scope, scratch_dir, read_opts),
         :ok <- validate_transition(manifest, previous_design(task)),
         {:ok, _design} <- Artifacts.capture_design(scope, task, scratch_dir, capture_opts) do
      run
    else
      {:error, reason} -> fail(run, reason)
    end
  end

  defp fail(%Run{} = run, reason) do
    error = if is_binary(reason), do: reason, else: inspect(reason)
    {:ok, run} = run |> Run.changeset(%{error: error}) |> Repo.update()
    run
  end

  defp previous_design(%Task{id: task_id}) do
    Repo.one(
      from d in Design,
        where: d.task_id == ^task_id,
        order_by: [desc: d.version],
        limit: 1
    )
  end

  defp validate_transition(_manifest, nil), do: :ok

  defp validate_transition(manifest, %Design{} = prev) do
    cond do
      prev.picked_key != nil and (is_nil(manifest.picked_key) or manifest.picked_key == "") ->
        {:error, "Design manifest is missing pickedKey (expected \"#{prev.picked_key}\")."}

      prev.picked_key != nil and manifest.picked_key != prev.picked_key ->
        {:error,
         "Design manifest pickedKey (#{manifest.picked_key}) does not match chosen direction (#{prev.picked_key})."}

      prev.picked_key != nil and not direction_present?(manifest.directions, prev.picked_key) ->
        {:error, "Manifest missing picked direction: #{prev.picked_key}"}

      manifest.version <= prev.version ->
        {:error, "Manifest version must be incremented after a pick or revision."}

      true ->
        :ok
    end
  end

  defp direction_present?(directions, key) when is_binary(key) do
    is_list(directions) and Enum.any?(directions, fn direction -> Map.get(direction, :key) == key end)
  end
end
