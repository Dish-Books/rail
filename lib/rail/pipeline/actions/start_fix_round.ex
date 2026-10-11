defmodule Rail.Pipeline.Actions.StartFixRound do
  @moduledoc """
  What a person's Send in the Review tray does once every finding is ruled: the Review run is reopened and resumed
  on the findings ruled Fix, a carried one included, with their rules and places, then the sender's unsent finding,
  diff and screen comments, as one message, and the task stays at Review. With nothing to send it reads Finish
  review, which finishes the review and takes the pull request out of draft. After that, a Send of comments resumes
  the lead on them alone.

  What was ruled and sent is learned from, since a ruling can change until now: a Fix on a suppressed finding
  overrides its rule, and every other Fix and every comment is a correction.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastDiffComments
  import Rail.Pipeline.Utils.BroadcastFindingComments
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.BroadcastScreenComments
  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.FinishReview
  import Rail.Pipeline.Utils.SendBack

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @running [:starting, :running, :waiting_for_resources, :waiting_for_usage]

  @fix_steps "Hand them to the engineer whole, every place included. Have the code reviewer read the uncommitted diff against them, and an explorer re-check any screen a fix touched, then have the engineer commit the fixes. Save each finding with `save_finding`, status fixed, the places its fix covered and those it left with why, the test that failed first and the files it changed, and end your turn: Rail sends the commit on."

  @comment_steps "The comments are not findings: never save one with `save_finding`. Have the engineer act on each in this round, open a screen comment's picture at the path it gives, and have the engineer commit what they change. In your last message, say what was done with each comment, by its number, and why."

  @doc """
  Sends the Review tray of the scope user on `run`, the task's Review run. Returns `{:ok, run}` as it now stands, or
  `{:error, reason}` while a finding is undecided, the run works, there is nothing left to start, or a review with
  nothing to fix would finish on a commit CI has not passed.
  """
  def start_fix_round(%Scope{} = scope, %Run{} = run) do
    run = Run |> Repo.get!(run.id) |> Repo.preload([task: [:issue, :project, :runs]], force: true)
    findings = Pipeline.list_findings(run.task)
    passes = Pipeline.read_review(run.task)
    finished? = passes != [] and List.last(passes).finished_at != nil

    fix = Enum.filter(findings, &Finding.outstanding?/1)

    with :ok <- startable(run.task, findings, passes),
         claimed = claim(scope, run.task),
         comments = claimed.finding ++ claimed.diff ++ claimed.screen,
         :ok <- sendable(run.task, finished?, fix, comments) do
      if fix == [] and comments == [],
        do: finish(run),
        else: resume(run, Map.put(claimed, :fix, fix), length(passes))
    end
  end

  defp startable(%Task{stage: stage}, _findings, _passes) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp startable(%Task{} = task, findings, passes) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      passes == [] -> {:error, :nothing_to_start}
      Enum.any?(findings, &Finding.undecided?/1) -> {:error, :findings_undecided}
      true -> :ok
    end
  end

  # A finished review is finished once, so only comments can resume it.
  defp sendable(%Task{}, true, _fix, []), do: {:error, :nothing_to_start}
  defp sendable(%Task{}, true, _fix, _comments), do: :ok

  # A fix whose commit has not passed CI is still waiting on it, however it was ruled.
  defp sendable(%Task{project: %Project{ci_command: command}} = task, false, [], []) when command not in [nil, ""] do
    if ci_passed?(task), do: :ok, else: {:error, :ci_not_passed}
  end

  defp sendable(%Task{}, false, _fix, _comments), do: :ok

  # Claimed before sending, so a second tab's Send finds nothing left to send. Committed rather than held in a
  # transaction: the spawn reads the run from another process, which would not see an uncommitted note.
  defp claim(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    now = DateTime.utc_now()

    {_claimed, finding} =
      Repo.update_all(
        from(c in FindingComment,
          where: c.task_id == ^task_id and c.user_id == ^user_id and c.status == :unsent,
          select: c
        ),
        set: [status: :sent, updated_at: now]
      )

    {_claimed, diff} =
      Repo.update_all(
        from(c in DiffComment, where: c.task_id == ^task_id and c.user_id == ^user_id and c.status == :unsent, select: c),
        set: [status: :sent, updated_at: now]
      )

    {_claimed, screen} =
      Repo.update_all(
        from(c in ScreenComment,
          where: c.task_id == ^task_id and c.user_id == ^user_id and c.status == :unsent,
          select: c
        ),
        set: [status: :sent, updated_at: now]
      )

    # The order the tray numbers them in.
    %{
      finding: finding |> Repo.preload(:finding) |> FindingComment.calculate_order(),
      diff: DiffComment.calculate_order(diff),
      screen: Enum.sort_by(screen, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
    }
  end

  defp claim(%Scope{}, %Task{}), do: %{finding: [], diff: [], screen: []}

  # Finishing the review is when its run completes, which every page showing the task hears. A chat turn that
  # stopped or failed left the lead in progress with its error, which the finished review settles.
  defp finish(%Run{} = run) do
    send_back(run.task, :review_lead, "Finish review: nothing was ruled Fix.")
    _task = finish_review(run.task)

    {:ok, finished} =
      run |> Run.changeset(%{completed_at: DateTime.utc_now(), stage_outcome: :done, error: nil}) |> Repo.update()

    broadcast_pipeline_changed(run.task)
    {:ok, finished}
  end

  # The note is consumed by the spawn and never written anywhere, so the conversation keeps it too. The run reads
  # running from here, and only one of two Sends racing for it moves it there, so only one spawns.
  defp resume(%Run{} = run, sent, round) do
    note = note(sent, round, Pipeline.list_screens(run.task), run.task.scratch_path)
    {:ok, role} = Roles.get_role(id: run.role_id)

    with {1, [reopened]} <- reopen(run, note),
         send_back(run.task, :review_lead, note),
         {:ok, os_process} <- Pipeline.start_review_run(%{reopened | task: run.task, role: role}) do
      # Learned only once the note is delivered, since a ruling can still change before the next Send.
      {overrides, corrections} = Enum.split_with(sent.fix, &is_binary(&1.suppressed_by_id))
      {:ok, _flagged} = Learnings.record_overrides(run.task, overrides)
      {:ok, _learned} = Learnings.record_corrections(run.task, corrections ++ sent.finding ++ sent.diff ++ sent.screen)
      sent(run.task, sent, os_process.run)
    else
      {0, []} ->
        unsend(sent)
        {:error, :stage_running}

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        spawn_failed(run.task, sent, failed)

      {:error, :dispatch_disabled} ->
        unstarted(run, sent, :dispatch_disabled)
    end
  end

  defp reopen(%Run{id: id}, note) do
    Repo.update_all(
      from(r in Run, where: r.id == ^id and r.status not in ^@running, select: r),
      set: [
        status: :running,
        stage_outcome: :in_progress,
        error: nil,
        ci_failure_streak: 0,
        completed_at: nil,
        pending_answer: note,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp sent(%Task{} = task, %{finding: finding, diff: diff, screen: screen}, %Run{} = run) do
    for user_id <- finding |> Enum.map(& &1.user_id) |> Enum.uniq(), do: broadcast_finding_comments(task.id, user_id)
    if diff != [], do: broadcast_diff_comments(task.id, :everyone)
    for user_id <- screen |> Enum.map(& &1.user_id) |> Enum.uniq(), do: broadcast_screen_comments(task.id, user_id)
    broadcast_pipeline_changed(task)

    {:ok, run}
  end

  # Nothing delivers the note a failed start leaves, so nothing of it is learned and its comments go back unsent.
  # The start already settled the run.
  defp spawn_failed(%Task{} = task, sent, %Run{} = failed) do
    unsend(sent)
    sent(task, sent, failed)
  end

  # Marked running before the spawn so a second click is refused; it goes back to how it read before, and the
  # comments to unsent, when nothing spawned.
  defp unstarted(%Run{} = before, sent, reason) do
    {:ok, _settled} =
      Run
      |> Repo.get!(before.id)
      |> Run.changeset(%{
        status: :finished,
        stage_outcome: before.stage_outcome,
        completed_at: before.completed_at,
        error: before.error
      })
      |> Repo.update()

    unsend(sent)
    {:error, reason}
  end

  defp unsend(%{finding: finding, diff: diff, screen: screen}) do
    for {schema, comments} <- [{FindingComment, finding}, {DiffComment, diff}, {ScreenComment, screen}],
        comments != [] do
      ids = Enum.map(comments, & &1.id)

      Repo.update_all(from(c in schema, where: c.id in ^ids and c.status == :sent),
        set: [status: :unsent, updated_at: DateTime.utc_now()]
      )
    end

    :ok
  end

  defp note(%{fix: fix, finding: finding, diff: diff, screen: screen}, round, screens, scratch_path) do
    comments =
      Enum.map(finding, &{"On a finding", FindingComment.calculate_block(&1)}) ++
        Enum.map(diff, &{"On the diff", DiffComment.calculate_block(&1)})

    comments =
      comments ++
        Enum.map(screen, fn comment ->
          {"On a screen",
           ScreenComment.calculate_block(comment, Enum.find(screens, &(&1.key == comment.key)), scratch_path)}
        end)

    numbered = comments |> Enum.with_index(1) |> Enum.map(fn {{on, block}, n} -> "#{n}. #{on}:\n#{block}" end)

    sections = [
      opening(fix, comments, round),
      Enum.map(fix, &finding/1),
      fix != [] && @fix_steps,
      numbered,
      comments != [] && @comment_steps
    ]

    (sections |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.join("\n\n")) <> "\n"
  end

  defp opening([], comments, round),
    do:
      "Start fix round #{round} on the human's #{count(comments, "comment")}. Nothing is ruled Fix this time: the comments are all of it."

  defp opening(fix, [], round),
    do:
      "Start fix round #{round}. The human ruled these #{length(fix)} findings Fix, and they are all of them: anything not here was ruled Don't fix or is already fixed."

  defp opening(fix, comments, round),
    do:
      "Start fix round #{round}. The human ruled these #{length(fix)} findings Fix, and they are all of them: anything not here was ruled Don't fix or is already fixed. Their #{count(comments, "comment")} follow the findings."

  defp count(items, word) when length(items) == 1, do: "1 #{word}"
  defp count(items, word), do: "#{length(items)} #{word}s"

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
