defmodule Rail.Pipeline.Actions.ParseStageVerdictTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.StageVerdict
  alias Rail.Pipeline
  alias Rail.Runs

  setup do
    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :finished,
        started_at: DateTime.utc_now()
      })

    %{role_run: role_run}
  end

  test "reads the verdict line the stage brief asks for", %{role_run: role_run} do
    Runs.append_run_event(role_run, "findings...\n\nVERDICT: APPROVED")

    assert %StageVerdict{verdict: :passed, status: :passed} = Pipeline.parse_stage_verdict(role_run)
  end

  for {line, expected} <- [
        {"VERDICT: CHANGES REQUESTED", :changes_requested},
        {"VERDICT: PASS", :passed},
        {"VERDICT: PASSED", :passed},
        {"VERDICT: FAIL", :changes_requested},
        {"VERDICT: FAILED", :changes_requested},
        {"## **Verdict:** `CHANGES REQUESTED`", :changes_requested},
        {"- **APPROVED**", :passed},
        {"> VERDICT: FAILED", :changes_requested}
      ] do
    test "reads #{inspect(line)} as #{expected}", %{role_run: role_run} do
      Runs.append_run_event(role_run, unquote(line))

      assert %StageVerdict{verdict: unquote(expected)} = Pipeline.parse_stage_verdict(role_run)
    end
  end

  test "takes the last verdict, since the words appear in the findings", %{role_run: role_run} do
    Runs.append_run_event(role_run, """
    [high] correctness lib/a.dart:12
    The check passed on the happy path only.
    I would have APPROVED this without the leak.

    VERDICT: CHANGES REQUESTED
    """)

    assert %StageVerdict{verdict: :changes_requested} = Pipeline.parse_stage_verdict(role_run)
  end

  test "ignores the pass/fail cells in a QA table", %{role_run: role_run} do
    Runs.append_run_event(role_run, """
    | check | result | severity | evidence |
    | --- | --- | --- | --- |
    | task persists a restart | pass | - | tasks/task-1.json |
    | hot restart mid-run | fail | blocker | console line 40 |

    VERDICT: FAIL
    """)

    assert %StageVerdict{verdict: :changes_requested} = Pipeline.parse_stage_verdict(role_run)
  end

  test "a sentence about the review is not a verdict line", %{role_run: role_run} do
    Runs.append_run_event(role_run, "APPROVED with three nits I have not listed")
    Runs.append_run_event(role_run, "This would have passed if the timer were disposed")

    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(role_run)
  end

  test "a run that states none is unclear rather than a guess", %{role_run: role_run} do
    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(role_run)

    Runs.append_run_event(role_run, "I could not read the diff; the worktree was gone.")

    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(role_run)
  end

  test "an explained verdict captures its explanation", %{role_run: role_run} do
    Runs.append_run_event(role_run, "VERDICT: APPROVED - the nits can follow up")

    assert %StageVerdict{verdict: :passed, explanation: "the nits can follow up"} =
             Pipeline.parse_stage_verdict(role_run)
  end

  test "an unexplained verdict has no explanation", %{role_run: role_run} do
    Runs.append_run_event(role_run, "APPROVED.")

    assert %StageVerdict{verdict: :passed, explanation: nil} = Pipeline.parse_stage_verdict(role_run)
  end

  test "chat after a verdict does not change it", %{role_run: role_run} do
    Runs.append_run_event(role_run, "Looks good to me.\n\nVERDICT: APPROVED")
    Runs.append_run_event(role_run, "[human] are you sure about the timer?")
    Runs.append_run_event(role_run, "Yes - the widget disposes it, so that one passed for me.")

    assert %StageVerdict{verdict: :passed} = Pipeline.parse_stage_verdict(role_run)
  end

  test "a second verdict supersedes the first", %{role_run: role_run} do
    Runs.append_run_event(role_run, "Looks good to me.\n\nVERDICT: APPROVED")
    Runs.append_run_event(role_run, "[human] take another look at the leak")
    Runs.append_run_event(role_run, "You are right, it leaks.\n\nVERDICT: CHANGES REQUESTED")

    assert %StageVerdict{verdict: :changes_requested} = Pipeline.parse_stage_verdict(role_run)
  end

  test "reads the verdict out of the raw CLI stream, not just plain lines", %{role_run: role_run} do
    Runs.append_run_event(
      role_run,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "Reviewed.\n\nVERDICT: PASSED"}]}
      })
    )

    assert %StageVerdict{verdict: :passed} = Pipeline.parse_stage_verdict(role_run)
  end

  test "tool summaries cannot supply a verdict", %{role_run: role_run} do
    Runs.append_run_event(
      role_run,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "name" => "bash", "input" => %{"command" => "echo APPROVED"}}]
        }
      })
    )

    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(role_run)
  end

  test "returns unclear for an unknown role run" do
    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict("rr_000000000000000000000000")
  end
end
