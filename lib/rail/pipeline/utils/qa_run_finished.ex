defmodule Rail.Pipeline.Utils.QaRunFinished do
  @moduledoc """
  Where a finished QA run leaves its task.

  The findings are recorded and, while any of them is waiting on a human, the
  task stays at QA: QA reports and a person decides, so a pass that drove the
  whole application still moves nothing.

  A pass that leaves nothing to decide is the exception. No findings, or every
  one of them fixed or already dismissed, is exactly what `send_to_demo/1` would
  let through, so it goes on to demo by itself - on the first pass or on a
  re-test that found the engineer fixed everything. A message the human queued
  for QA holds it here: they have something more to say to this stage.

  A report with a finding that shows no evidence is not valid, so none of it is
  recorded: it goes back to QA naming those findings, twice, and then the run
  carries an error instead. What a QA run can also get wrong is exiting cleanly
  having written no report, and that is recorded on the run the same way.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @limit QaReport.evidence_reminder_limit()

  @doc "Finishes `run` as the QA stage."
  def qa_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)

    case Pipeline.read_qa_report(task) do
      %QaReport{} = report -> report_finished(run, task, report, QaReport.unproven(report))
      nil -> update(run, %{error: "The QA agent did not write #{report_file(task)}."})
    end
  end

  defp report_finished(%Run{} = run, %Task{} = task, %QaReport{findings: findings}, []) do
    if run.evidence_reminders > 0 do
      Pipeline.append_run_events(run.id, nil, [
        "[rail] Every finding carries evidence. #{count(findings)} #{if length(findings) == 1, do: "is", else: "are"} ready for your call."
      ])
    end

    {:ok, _synced} = Pipeline.sync_qa_findings(task, findings)
    run |> update(%{evidence_reminders: 0}) |> advance()
  end

  defp report_finished(%Run{evidence_reminders: reminders} = run, %Task{}, %QaReport{}, unproven)
       when reminders >= @limit do
    Pipeline.append_run_events(run.id, nil, [
      "[rail] QA reported #{count(unproven)} without evidence after #{@limit} reminders. Rail stopped asking."
    ])

    update(run, %{
      stage_outcome: :in_progress,
      error:
        "QA's report still has #{count(unproven)} without evidence after #{@limit} reminders. " <>
          "They are named in the QA sidebar."
    })
  end

  defp report_finished(%Run{evidence_reminders: reminders} = run, %Task{} = task, %QaReport{}, unproven) do
    reminder = "reminder #{reminders + 1} of #{@limit}"
    note = note(task, unproven)

    Pipeline.append_run_events(run.id, nil, [
      "[rail] #{count(unproven)} had no evidence, so the report went back to QA (#{reminders + 1} of #{@limit})."
      | Enum.map(String.split(note, "\n"), &String.trim_trailing("[#{reminder}] #{&1}"))
    ])

    briefed =
      update(run, %{
        evidence_reminders: reminders + 1,
        stage_outcome: :in_progress,
        pending_answer: note,
        status: :running,
        error: nil
      })

    case Pipeline.start_qa_run(briefed) do
      {:ok, %OsProcess{run: %Run{} = resumed}} ->
        resumed

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        failed

      {:error, :dispatch_disabled} ->
        update(briefed, %{status: :finished, error: "Dispatch is off, so QA was not resumed."})
    end
  end

  # `send_to_demo/1` is the one place that decides whether QA is closed, so it
  # is asked rather than restated here; a refusal is QA still open.
  defp advance(%Run{pending_chat: nil} = run) do
    case Pipeline.send_to_demo(run) do
      {:ok, %Run{} = sent} -> sent
      {:error, _still_open} -> run
    end
  end

  defp advance(%Run{} = run), do: run

  defp note(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}, unproven) do
    String.trim("""
    This report is not valid yet. Every finding has to carry evidence of what is wrong, and #{count(unproven)} #{if length(unproven) == 1, do: "does", else: "do"} not:

    #{Enum.map_join(unproven, "\n", &unproven_line/1)}

    Attach a screenshot, log, query or note that shows the defect, and write #{Path.join([scratch_path, "qa", "#{identifier}.json"])} again. Evidence has to be inside your QA folder; a path outside it is refused and does not count.
    """)
  end

  defp unproven_line(%{title: title, key: key, refused: []}), do: "- #{title} (#{key}): no evidence attached."

  defp unproven_line(%{title: title, key: key, refused: refused}) do
    "- #{title} (#{key}): evidence refused: #{Enum.join(refused, "; ")}."
  end

  defp count([_one]), do: "1 finding"
  defp count(findings), do: "#{length(findings)} findings"

  defp report_file(%Task{issue: %Issue{identifier: identifier}}), do: "qa/#{identifier}.json"

  defp update(%Run{} = run, attrs) do
    {:ok, updated} = run |> Run.changeset(attrs) |> Repo.update()
    %{updated | task: run.task, role: run.role}
  end
end
