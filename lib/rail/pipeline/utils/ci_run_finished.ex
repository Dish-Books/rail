defmodule Rail.Pipeline.Utils.CiRunFinished do
  @moduledoc """
  Where a finished CI run leaves the engineer's run.

  A pass is what lets the branch be pushed, and the stage be done, and sends the
  work to review when a human's commit or CI run asked for that. A failure goes
  back to the engineer with the output that says why, until it has failed three
  times in a row with nobody stepping in; then it waits for a person.
  """

  import Rail.Pipeline.Utils.EnqueuePullRequest
  import Rail.Pipeline.Utils.TurnStamp

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @failure_limit 3
  @tail_lines 150

  @doc "Finishes `run` after `os_process`, its CI, exited."
  def ci_run_finished(%Run{exit_code: 0, task: %Task{} = task} = run, %OsProcess{}) do
    case Git.push_branch(Scope.for_system(), task) do
      :ok ->
        attrs = %{ci_failure_streak: 0, error: nil, stage_outcome: :done, review_on_ci_pass: false}
        _job = enqueue_pull_request(task)
        pushed = update(run, attrs)

        # A message queued while CI ran is the engineer about to work again, which
        # review cannot see once the run has settled.
        if run.review_on_ci_pass and is_nil(run.pending_chat), do: send_on_to_review(pushed), else: pushed

      {:error, reason} ->
        update(run, %{
          review_on_ci_pass: false,
          error: "CI passed, but the branch could not be pushed: #{describe(reason)}"
        })
    end
  end

  # Nothing the engineer wrote stopped it: a person did, or Rail restarted
  # without seeing it finish.
  def ci_run_finished(%Run{exit_code: -1} = run, %OsProcess{}) do
    update(run, %{
      review_on_ci_pass: false,
      error: "CI was stopped before it finished. Run it again from the diff when ready."
    })
  end

  def ci_run_finished(%Run{ci_failure_streak: streak} = run, %OsProcess{}) when streak + 1 >= @failure_limit do
    update(run, %{
      ci_failure_streak: streak + 1,
      review_on_ci_pass: false,
      error:
        "CI failed #{streak + 1} times in a row, so it was not sent back again. " <>
          "Read its output, then message the engineer or run CI again."
    })
  end

  def ci_run_finished(%Run{ci_failure_streak: streak} = run, %OsProcess{} = os_process) do
    Pipeline.append_run_events(run.id, nil, [
      "[rail] CI failed, so its output went back to the engineer (#{streak + 1} of #{@failure_limit})."
    ])

    # The fix turn's end compares against this to tell whether the engineer changed code.
    briefed =
      update(
        run,
        Map.merge(turn_stamp(run.task), %{
          ci_failure_streak: streak + 1,
          review_on_ci_pass: false,
          pending_answer: note(run, os_process),
          status: :running,
          error: nil
        })
      )

    # Each turn's system prompt is the one it is spawned with, so it is read as the repo has it now.
    {:ok, role} = Roles.get_role(id: run.role_id)

    case Pipeline.start_engineer_run(%{briefed | role: role}) do
      {:ok, %OsProcess{run: %Run{} = resumed}} ->
        resumed

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        failed

      {:error, :dispatch_disabled} ->
        update(briefed, %{status: :finished, error: "Dispatch is off, so the engineer was not resumed."})
    end
  end

  defp send_on_to_review(%Run{} = pushed) do
    case Pipeline.send_to_review(pushed) do
      {:ok, %Run{} = sent} ->
        %{sent | task: pushed.task, role: pushed.role}

      {:error, reason} ->
        Pipeline.append_run_events(pushed.id, nil, [
          "[rail] CI passed, but the work was not sent to review: #{describe(reason)}"
        ])

        pushed
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
