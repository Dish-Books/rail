defmodule Rail.Pipeline.Actions.SettleDesignRun do
  @moduledoc """
  Settles a finished design-stage run.

  The designer reports through a manifest in the task's scratch directory. A
  revision has to keep the direction a human already picked and move the version
  forward; anything else fails the stage rather than quietly replacing the design
  that was chosen.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.AdvanceStage

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc "Settles the finished design `run` against `outcome`."
  def settle_design_run(%Run{} = run, _outcome \\ %{}, opts \\ []) do
    advance_stage(run, opts, &capture_design/3)
  end

  defp capture_design(%Task{scratch_path: scratch_dir} = task, role_run, opts) do
    scope = Scope.for_system()
    read_opts = Keyword.take(opts, [:url_probe, :req_options])
    capture_opts = Keyword.take(opts, [:project, :issue, :owner_user, :url_probe, :req_options])

    with {:ok, manifest} <- Artifacts.read_design(scope, scratch_dir, read_opts),
         :ok <- validate_transition(manifest, previous_design(task)),
         {:ok, _design} <- Artifacts.capture_design(scope, task, scratch_dir, capture_opts) do
      {:ok, role_run} = role_run |> RoleRun.changeset(%{auto_retries: 0}) |> Repo.update()

      {%{stage_state: :awaiting_approval, retry_after: nil, error: nil}, role_run}
    else
      {:error, reason} ->
        error = if is_binary(reason), do: reason, else: inspect(reason)

        {%{stage_state: :failed, error: error, retry_after: nil}, role_run}
    end
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
