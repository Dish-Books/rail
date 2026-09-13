defmodule Rail.Pipeline.Actions.ParseStageVerdictTest do
  use Rail.DataCase, async: true

  alias Rail.Backends
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.StageVerdict
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} = Backends.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Verdict Workspace",
        external_id: "lin_ws_verdict",
        token: "lin_api_token_verdict",
        webhook_secret: "whsec_verdict"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Verdict Project",
        linear_workspace_id: workspace.id,
        github_repo: "org/verdict",
        github_installation_id: 31_001,
        linear_team_id: "team_verdict",
        linear_team_key: "VDT",
        default_branch: "main",
        clone_path: "/tmp/repos/verdict",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the reviewer."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_verdict_1",
      "identifier" => "VDT-1",
      "title" => "Verdict Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Verdict Issue"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    %{run: run}
  end

  test "reads the verdict line the stage brief asks for", %{run: run} do
    Runs.append_run_event(run, "findings...\n\nVERDICT: APPROVED")

    assert %StageVerdict{verdict: :passed, status: :passed} = Pipeline.parse_stage_verdict(run)
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
    test "reads #{inspect(line)} as #{expected}", %{run: run} do
      Runs.append_run_event(run, unquote(line))

      assert %StageVerdict{verdict: unquote(expected)} = Pipeline.parse_stage_verdict(run)
    end
  end

  test "takes the last verdict, since the words appear in the findings", %{run: run} do
    Runs.append_run_event(run, """
    [high] correctness lib/a.dart:12
    The check passed on the happy path only.
    I would have APPROVED this without the leak.

    VERDICT: CHANGES REQUESTED
    """)

    assert %StageVerdict{verdict: :changes_requested} = Pipeline.parse_stage_verdict(run)
  end

  test "ignores the pass/fail cells in a QA table", %{run: run} do
    Runs.append_run_event(run, """
    | check | result | severity | evidence |
    | --- | --- | --- | --- |
    | task persists a restart | pass | - | tasks/task-1.json |
    | hot restart mid-run | fail | blocker | console line 40 |

    VERDICT: FAIL
    """)

    assert %StageVerdict{verdict: :changes_requested} = Pipeline.parse_stage_verdict(run)
  end

  test "a sentence about the review is not a verdict line", %{run: run} do
    Runs.append_run_event(run, "APPROVED with three nits I have not listed")
    Runs.append_run_event(run, "This would have passed if the timer were disposed")

    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(run)
  end

  test "a run that states none is unclear rather than a guess", %{run: run} do
    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(run)

    Runs.append_run_event(run, "I could not read the diff; the worktree was gone.")

    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(run)
  end

  test "an explained verdict captures its explanation", %{run: run} do
    Runs.append_run_event(run, "VERDICT: APPROVED - the nits can follow up")

    assert %StageVerdict{verdict: :passed, explanation: "the nits can follow up"} =
             Pipeline.parse_stage_verdict(run)
  end

  test "an unexplained verdict has no explanation", %{run: run} do
    Runs.append_run_event(run, "APPROVED.")

    assert %StageVerdict{verdict: :passed, explanation: nil} = Pipeline.parse_stage_verdict(run)
  end

  test "chat after a verdict does not change it", %{run: run} do
    Runs.append_run_event(run, "Looks good to me.\n\nVERDICT: APPROVED")
    Runs.append_run_event(run, "[human] are you sure about the timer?")
    Runs.append_run_event(run, "Yes - the widget disposes it, so that one passed for me.")

    assert %StageVerdict{verdict: :passed} = Pipeline.parse_stage_verdict(run)
  end

  test "a second verdict supersedes the first", %{run: run} do
    Runs.append_run_event(run, "Looks good to me.\n\nVERDICT: APPROVED")
    Runs.append_run_event(run, "[human] take another look at the leak")
    Runs.append_run_event(run, "You are right, it leaks.\n\nVERDICT: CHANGES REQUESTED")

    assert %StageVerdict{verdict: :changes_requested} = Pipeline.parse_stage_verdict(run)
  end

  test "reads the verdict out of the raw CLI stream, not just plain lines", %{run: run} do
    Runs.append_run_event(
      run,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "Reviewed.\n\nVERDICT: PASSED"}]}
      })
    )

    assert %StageVerdict{verdict: :passed} = Pipeline.parse_stage_verdict(run)
  end

  test "tool summaries cannot supply a verdict", %{run: run} do
    Runs.append_run_event(
      run,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "name" => "bash", "input" => %{"command" => "echo APPROVED"}}]
        }
      })
    )

    assert %StageVerdict{verdict: :unclear} = Pipeline.parse_stage_verdict(run)
  end
end
