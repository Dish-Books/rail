defmodule Rail.Pipeline.Utils.QaRunFinished do
  @moduledoc """
  Where a finished QA-stage run leaves its task.

  QA reports through a manifest in the task's scratch directory. The report lives
  there or nowhere: a run that left no manifest has not reported, whatever its
  exit code said, and the stage fails rather than falling through to the gate.
  Once the report is captured, the verdict is read like any other gate's.
  """

  import Rail.Pipeline.Utils.AdvanceStage
  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Artifacts
  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc "Settles the finished QA `run` against `outcome`."
  def finish_qa_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &capture_report/3)
  end

  defp capture_report(%Task{scratch_path: scratch_dir} = task, run, opts) do
    scope = Scope.for_system()

    if manifest_exists?(scratch_dir) do
      case Artifacts.read_qa_report(scope, scratch_dir, Keyword.take(opts, [:req_options])) do
        {:ok, qa_data} -> capture_and_gate(scope, task, run, qa_data, opts)
        {:error, reason} -> fail_stage(run, reason)
      end
    else
      fail_stage(run, "QA left no manifest at #{Path.join([scratch_dir, "qa", "manifest.json"])}.")
    end
  end

  defp capture_and_gate(scope, %Task{scratch_path: scratch_dir} = task, run, qa_data, opts) do
    capture_opts =
      opts
      |> Keyword.take([:req_options, :project, :issue, :owner_user])
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:commit, head_sha(task, run) || qa_data[:commit])

    case Artifacts.capture_qa_report(scope, task, scratch_dir, capture_opts) do
      {:ok, _report} -> gate_outcome(task, run, :qa_lead)
      {:error, reason} -> fail_stage(run, reason)
    end
  end

  defp fail_stage(run, reason) do
    error = if is_binary(reason), do: reason, else: inspect(reason)

    {%{stage_state: :failed, error: error, retry_after: nil}, run}
  end

  defp manifest_exists?(scratch_dir) do
    is_binary(scratch_dir) and
      (File.exists?(Path.join(scratch_dir, "manifest.json")) or
         File.exists?(Path.join([scratch_dir, "qa", "manifest.json"])))
  end

  defp head_sha(%Task{worktree_path: path}, %Run{} = run) when is_binary(path) do
    case Git.branch_fingerprint(path) do
      %{head_sha: sha} -> sha
      _other -> run.stage_fingerprint_head_sha
    end
  end

  defp head_sha(_task, %Run{stage_fingerprint_head_sha: sha}), do: sha
end
