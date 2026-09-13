defmodule Rail.Pipeline.Utils.QaRunFinished do
  @moduledoc """
  Where a finished QA run leaves its task.

  QA reports through a manifest in the task's scratch directory. The report lives
  there or nowhere: a run that left no manifest has not reported, whatever it said
  in its verdict, and that is recorded on the run rather than falling through to
  the gate. Once the report is captured, the verdict is read like any other gate's.
  """

  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Artifacts
  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc "Finishes `run` as the QA stage."
  def qa_run_finished(%Run{task: %Task{scratch_path: scratch_dir} = task} = run, opts) do
    scope = Scope.for_system()

    if manifest_exists?(scratch_dir) do
      case Artifacts.read_qa_report(scope, scratch_dir, Keyword.take(opts, [:req_options])) do
        {:ok, qa_data} -> capture_and_gate(scope, task, run, qa_data, opts)
        {:error, reason} -> fail(run, reason)
      end
    else
      fail(run, "QA left no manifest at #{Path.join([scratch_dir, "qa", "manifest.json"])}.")
    end
  end

  defp capture_and_gate(scope, %Task{scratch_path: scratch_dir} = task, %Run{} = run, qa_data, opts) do
    capture_opts =
      opts
      |> Keyword.take([:req_options, :project, :issue, :owner_user])
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:commit, head_sha(task, run) || qa_data[:commit])

    case Artifacts.capture_qa_report(scope, task, scratch_dir, capture_opts) do
      {:ok, _report} -> gate_outcome(run, :qa_lead, opts)
      {:error, reason} -> fail(run, reason)
    end
  end

  defp fail(%Run{task: task} = run, reason) do
    error = if is_binary(reason), do: reason, else: inspect(reason)
    {:ok, run} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{run | task: task}
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
