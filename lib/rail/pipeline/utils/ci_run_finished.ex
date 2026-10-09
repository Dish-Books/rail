defmodule Rail.Pipeline.Utils.CiRunFinished do
  @moduledoc """
  Where a finished CI run leaves the run it ran on, the engineer's or the Review lead's.

  A pass is what lets the branch be pushed. On the engineer's run it settles the
  stage and sends the work to Review when a commit asked for that; on the Review
  lead's it starts the next round. A failure goes back to that run's own agent
  with the output that says why, until it has failed three times in a row with
  nobody stepping in; then it waits for a person.
  """

  import Rail.Pipeline.Utils.OpenPullRequest
  import Rail.Pipeline.Utils.StartNextRound

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @failure_limit 3
  @tail_lines 150

  @doc "Finishes `run` after `os_process`, its CI, exited."
  def ci_run_finished(%Run{exit_code: 0, role: %Role{stage: :review_lead}, task: %Task{} = task} = run, %OsProcess{} = ci) do
    case Git.push_branch(Scope.for_system(), task) do
      :ok ->
        pushed = %{update(run, %{ci_failure_streak: 0, error: nil}) | task: open_pull_request(task, run)}
        short = if ci.head_sha, do: " on #{String.slice(ci.head_sha, 0, 7)}", else: ""

        case start_next_round(pushed, "CI passed#{short}") do
          :ok -> %{Repo.get!(Run, run.id) | task: pushed.task, role: run.role}
          {:error, text} -> update(pushed, %{error: text})
        end

      {:error, reason} ->
        update(run, %{error: "CI passed, but the branch could not be pushed: #{describe(reason)}"})
    end
  end

  def ci_run_finished(%Run{exit_code: 0, task: %Task{} = task} = run, %OsProcess{}) do
    case Git.push_branch(Scope.for_system(), task) do
      :ok ->
        attrs = %{ci_failure_streak: 0, error: nil, stage_outcome: :done, review_on_ci_pass: false}
        pushed = %{update(run, attrs) | task: open_pull_request(task, run)}

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
      error: "CI was stopped before it finished. #{again(run)}"
    })
  end

  def ci_run_finished(%Run{ci_failure_streak: streak} = run, %OsProcess{}) when streak + 1 >= @failure_limit do
    update(run, %{
      ci_failure_streak: streak + 1,
      review_on_ci_pass: false,
      error: "CI failed #{streak + 1} times in a row, so it was not sent back again. Read its output, then #{who(run)}."
    })
  end

  def ci_run_finished(%Run{ci_failure_streak: streak} = run, %OsProcess{} = os_process) do
    Pipeline.append_run_events(run.id, nil, [
      "[rail] CI failed, so its output went back to the #{agent(run)} (#{streak + 1} of #{@failure_limit})."
    ])

    briefed =
      update(run, %{
        ci_failure_streak: streak + 1,
        review_on_ci_pass: false,
        pending_answer: note(run, os_process),
        status: :running,
        error: nil
      })

    # Each turn's system prompt is the one it is spawned with, so it is read as the repo has it now.
    {:ok, role} = Roles.get_role(id: run.role_id)

    case resume(%{briefed | role: role}) do
      {:ok, %OsProcess{run: %Run{} = resumed}} ->
        resumed

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        failed

      {:error, :dispatch_disabled} ->
        update(briefed, %{status: :finished, error: "Dispatch is off, so the #{agent(run)} was not resumed."})
    end
  end

  defp resume(%Run{role: %Role{stage: :review_lead}} = run), do: Pipeline.start_review_run(run)
  defp resume(%Run{} = run), do: Pipeline.start_engineer_run(run)

  defp agent(%Run{role: %Role{stage: :review_lead}}), do: "Review lead"
  defp agent(%Run{}), do: "engineer"

  defp again(%Run{role: %Role{stage: :review_lead}}), do: "Message the Review lead or Retry when ready."
  defp again(%Run{}), do: "Run it again from the diff when ready."

  defp who(%Run{role: %Role{stage: :review_lead}}), do: "message the Review lead or Retry"
  defp who(%Run{}), do: "message the engineer or run CI again"

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

  defp note(%Run{exit_code: exit_code} = run, %OsProcess{command: command, stream_path: stream_path}) do
    how = if exit_code == 124, do: "timed out and was stopped", else: "exited with code #{exit_code}"

    tail =
      case File.read(stream_path) do
        {:ok, output} -> output |> Tools.plain_text() |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n")
        {:error, _missing} -> ""
      end

    """
    CI failed on the last commit: `#{command}` #{how}.

    The end of its output:

    ```
    #{String.trim(tail)}
    ```

    The whole log is #{stream_path}. #{next_step(run)}
    """
  end

  defp next_step(%Run{role: %Role{stage: :review_lead}}) do
    "Have the engineer fix what it reports, have the code reviewer read the change, then call `commit_fixes` " <>
      "again, listing each changed file in `other_files` with why. When the failure is not the change's to fix, " <>
      "such as a flaky test elsewhere, call `commit_fixes` without changing anything and Rail runs CI again on the " <>
      "same commit."
  end

  defp next_step(%Run{}) do
    "Fix what it reports, then call `commit` again with a message for this round. Rail runs CI once more when " <>
      "you do. When the failure is not your change's to fix, such as a flaky test elsewhere, call `commit` without " <>
      "changing anything and Rail runs CI again on the same commit. When it failed on a change that landed on the " <>
      "default branch, call `request_merge` instead."
  end

  defp update(%Run{} = run, attrs) do
    {:ok, updated} = run |> Run.changeset(attrs) |> Repo.update()
    %{updated | task: run.task, role: run.role}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
