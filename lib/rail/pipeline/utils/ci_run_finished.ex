defmodule Rail.Pipeline.Utils.CiRunFinished do
  @moduledoc """
  Where a finished CI run leaves the engineer's run.

  A pass is what lets the branch be pushed, and the stage be done. A failure goes
  back to the engineer with the output that says why, until it has failed three
  times in a row with nobody stepping in; then it waits for a person.
  """

  import Rail.Pipeline.Utils.OpenPullRequest

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @failure_limit 3
  @tail_lines 150

  @doc "Finishes `run` after `os_process`, its CI, exited."
  def ci_run_finished(%Run{exit_code: 0, task: %Task{} = task} = run, %OsProcess{}) do
    case Git.push_branch(Scope.for_system(), task) do
      :ok ->
        %{update(run, %{ci_failure_streak: 0, error: nil, stage_outcome: :done}) | task: open_pull_request(task, run)}

      {:error, reason} ->
        update(run, %{error: "CI passed, but the branch could not be pushed: #{describe(reason)}"})
    end
  end

  # Nothing the engineer wrote stopped it: a person did, or Rail restarted
  # without seeing it finish.
  def ci_run_finished(%Run{exit_code: -1} = run, %OsProcess{}) do
    update(run, %{error: "CI was stopped before it finished. Run it again from the diff when ready."})
  end

  def ci_run_finished(%Run{ci_failure_streak: streak} = run, %OsProcess{}) when streak + 1 >= @failure_limit do
    update(run, %{
      ci_failure_streak: streak + 1,
      error:
        "CI failed #{streak + 1} times in a row, so it was not sent back again. " <>
          "Read its output, then message the engineer or run CI again."
    })
  end

  def ci_run_finished(%Run{ci_failure_streak: streak} = run, %OsProcess{} = os_process) do
    Pipeline.append_run_events(run.id, nil, [
      "[rail] CI failed, so its output went back to the engineer (#{streak + 1} of #{@failure_limit})."
    ])

    briefed =
      update(run, %{ci_failure_streak: streak + 1, pending_answer: note(run, os_process), status: :running, error: nil})

    case Pipeline.start_engineer_run(briefed) do
      {:ok, %OsProcess{run: %Run{} = resumed}} ->
        resumed

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        failed

      {:error, :dispatch_disabled} ->
        update(briefed, %{status: :finished, error: "Dispatch is off, so the engineer was not resumed."})
    end
  end

  defp note(%Run{exit_code: exit_code}, %OsProcess{command: command, stream_path: stream_path}) do
    how = if exit_code == 124, do: "timed out and was stopped", else: "exited with code #{exit_code}"

    tail =
      case File.read(stream_path) do
        {:ok, output} -> output |> Tools.plain_text() |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n")
        {:error, _missing} -> ""
      end

    """
    CI failed on your last commit: `#{command}` #{how}.

    The end of its output:

    ```
    #{String.trim(tail)}
    ```

    The whole log is #{stream_path}. Fix what it reports, then finish the round as before, writing the commit message again. Rail runs CI once more when you do.
    """
  end

  defp update(%Run{} = run, attrs) do
    {:ok, updated} = run |> Run.changeset(attrs) |> Repo.update()
    %{updated | task: run.task, role: run.role}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
