defmodule Rail.Pipeline.Actions.StartFixRound do
  @moduledoc """
  What a person's Start fix round does once every finding is ruled: the Review run is reopened and resumed
  on the findings ruled Fix, a carried one included, with their rules and places, and the task stays at
  Review. With nothing ruled Fix it reads Finish review, which finishes the review and takes the pull
  request out of draft.

  What was ruled is learned from, since a ruling can change until now: a Fix on a suppressed finding
  overrides its rule, and every other Fix is a correction.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.FinishReview
  import Rail.Pipeline.Utils.SendBack

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles

  @doc """
  Starts the fix round on `run`, the task's Review run. Returns `{:ok, run}` as it now stands, or
  `{:error, reason}` while a finding is undecided, the run works, or there is nothing left to start.
  """
  def start_fix_round(%Run{} = run) do
    run = Run |> Repo.get!(run.id) |> Repo.preload([task: [:issue, :runs]], force: true)
    findings = Pipeline.list_findings(run.task)
    passes = Pipeline.read_review(run.task)

    with :ok <- startable(run.task, findings, passes) do
      fix = Enum.filter(findings, &Finding.outstanding?/1)
      {overrides, corrections} = Enum.split_with(fix, &is_binary(&1.suppressed_by_id))
      {:ok, _flagged} = Learnings.record_overrides(run.task, overrides)
      {:ok, _learned} = Learnings.record_corrections(run.task, corrections)

      if fix == [], do: finish(run), else: resume(run, fix, length(passes))
    end
  end

  defp startable(%Task{stage: stage}, _findings, _passes) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp startable(%Task{} = task, findings, passes) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      passes == [] or List.last(passes).finished_at != nil -> {:error, :nothing_to_start}
      Enum.any?(findings, &Finding.undecided?/1) -> {:error, :findings_undecided}
      true -> :ok
    end
  end

  # Finishing the review is when its run completes, which every page showing the task hears.
  defp finish(%Run{} = run) do
    send_back(run.task, :review_lead, "Finish review: nothing was ruled Fix.")
    _task = finish_review(run.task)
    {:ok, finished} = run |> Run.changeset(%{completed_at: DateTime.utc_now()}) |> Repo.update()
    broadcast_pipeline_changed(run.task)
    {:ok, finished}
  end

  # The note is consumed by the spawn and never written anywhere, so the conversation keeps it too.
  defp resume(%Run{} = run, fix, round) do
    note = note(fix, round)
    send_back(run.task, :review_lead, note)

    {:ok, reopened} =
      run
      |> Run.changeset(%{stage_outcome: :in_progress, error: nil, ci_failure_streak: 0, pending_answer: note})
      |> Repo.update()

    {:ok, role} = Roles.get_role(id: run.role_id)

    case Pipeline.start_review_run(%{reopened | task: run.task, role: role}) do
      {:ok, os_process} -> {:ok, os_process.run}
      {:error, {:spawn_failed, _reason, %Run{} = failed}} -> {:ok, failed}
      {:error, :dispatch_disabled} -> {:error, :dispatch_disabled}
    end
  end

  defp note(fix, round) do
    """
    Start fix round #{round}. The human ruled these #{length(fix)} findings Fix, and they are all of them: anything not here was ruled Don't fix or is already fixed.

    #{Enum.map_join(fix, "\n\n", &finding/1)}

    Hand them to the engineer whole, every place included. Have the code reviewer read the uncommitted diff against them, and an explorer re-check any screen a fix touched, then call `commit`.
    """
  end

  # Tagged the way an issue's comments are, since the lead's own prose could otherwise read as the next finding.
  defp finding(%Finding{} = finding) do
    still = if finding.status == :not_fixed, do: ~s( still_failing="true"), else: ""

    places =
      finding.places
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {place, n} -> "#{n}. #{FindingPlace.describe(place)}#{label(place)}" end)

    String.trim("""
    <finding key="#{finding.key}" severity="#{finding.severity}" kind="#{finding.kind}"#{still}>
    #{finding.title}

    Rule: #{finding.rule}
    Problem: #{finding.problem}
    Where: #{Finding.where(finding)}
    Fix: #{finding.fix}
    Places:
    #{places}
    </finding>
    """)
  end

  defp label(%FindingPlace{label: label}) when is_binary(label), do: ", #{label}"
  defp label(%FindingPlace{}), do: ""
end
