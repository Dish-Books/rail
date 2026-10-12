defmodule Rail.Pipeline.Actions.StartFixRound do
  @moduledoc """
  What a person's Send in the Review tray does once every finding is ruled: the Review run is reopened and resumed
  on the findings ruled Fix, a carried one included, with their rules and places, then the sender's unsent finding,
  diff and screen comments, as one message that asks only for a fix plan, and the task stays at Review. With nothing
  to send it reads Finish review, which finishes the review and takes the pull request out of draft. After that, at
  Finalize and after the merge until cleanup, a Send of comments resumes the lead on them alone.

  While the round's fix plan waits on approval, a Send carries only what changed since the last one: rulings and
  new comments, for a revised plan. A round that changes down to nothing ends as Finish review does.

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
  import Rail.Pipeline.Utils.ReopenReviewRun
  import Rail.Pipeline.Utils.SendBack
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @plan_steps "Plan the round before anything changes: read the code each finding and comment touches, yourself or through the code reviewer, and save one fix plan with `save_fix_plan` that says, for each finding by its key and each comment by its number, what will change or why nothing will. Change nothing in the worktree and commit nothing: end your turn once the plan is saved. The human approves it in Rail, and that is what starts the engineer."

  @revise_steps "Revise the fix plan to match and save it again with `save_fix_plan`, covering every finding now ruled Fix and every comment of the round, then end your turn. Change nothing in the worktree and commit nothing."

  @comment_rules "The comments are not findings: never save one with `save_finding`. Open a screen comment's picture at the path it gives."

  @doc """
  Sends the Review tray of the scope user on `run`, the task's Review run. Returns `{:ok, run}` as it now stands, or
  `{:error, reason}` while a finding is undecided, the run works, there is nothing left to start, nothing changed
  while a fix plan waits, a review with nothing to fix would finish on a commit CI has not passed, or the task is
  cleaned up or not yet at Review.
  """
  def start_fix_round(%Scope{} = scope, %Run{} = run) do
    run = Run |> Repo.get!(run.id) |> Repo.preload([task: [:issue, :project, :runs]], force: true)
    findings = Pipeline.list_findings(run.task)
    passes = Pipeline.read_review(run.task)
    # Past Review the review is over whatever its last pass says, so only comments resume the lead there.
    finished? = run.task.stage != :review or (passes != [] and List.last(passes).finished_at != nil)

    # Nobody rules past Review, so a finding a later turn marked not fixed is not sent as Fix there.
    fix = if run.task.stage == :review, do: Enum.filter(findings, &Finding.outstanding?/1), else: []
    waiting = waiting_plan(Pipeline.read_fix_plan(run.task))
    changes = if waiting, do: FixPlan.calculate_ruling_changes(waiting, run.task, findings).unsent, else: []

    with :ok <- startable(run.task, findings, passes),
         claimed = claim(scope, run.task),
         comments = claimed.finding ++ claimed.diff ++ claimed.screen,
         :ok <- changed(waiting, changes, comments),
         :ok <- sendable(run.task, finished?, fix, if(waiting, do: waiting.comments ++ comments, else: comments)) do
      sent = Map.put(claimed, :fix, fix)

      cond do
        waiting != nil and fix == [] and waiting.comments == [] and comments == [] -> finish(run, waiting)
        waiting != nil -> revise(run, waiting, sent, changes)
        fix == [] and comments == [] -> finish(run, nil)
        true -> resume(run, sent, length(passes))
      end
    end
  end

  defp waiting_plan(%FixPlan{approved_at: nil} = fix_plan), do: fix_plan
  defp waiting_plan(_none_or_approved), do: nil

  # A plan waiting on approval is approved or changed: a Send with nothing new would only ask for the same plan.
  defp changed(%FixPlan{}, [], []), do: {:error, :fix_plan_waiting}
  defp changed(_waiting, _changes, _comments), do: :ok

  defp startable(%Task{cleaned_up_at: %DateTime{}}, _findings, _passes), do: {:error, :cleaned_up}

  defp startable(%Task{stage: stage}, _findings, _passes) when stage not in [:review, :finalize, :merged],
    do: {:error, {:invalid_stage, stage}}

  defp startable(%Task{} = task, findings, passes) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      passes == [] -> {:error, :nothing_to_start}
      # Nobody rules past Review, so a finding left unruled there holds nothing back.
      task.stage == :review and Enum.any?(findings, &Finding.undecided?/1) -> {:error, :findings_undecided}
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
  defp finish(%Run{} = run, waiting) do
    # A round changed down to nothing leaves no plan to approve, and its turns plan nothing more.
    if waiting, do: File.rm!(fix_plan_path(run.task))
    send_back(run.task, :review_lead, "Finish review: nothing was ruled Fix.")
    _task = finish_review(run.task)

    {:ok, finished} =
      run |> Run.changeset(%{completed_at: DateTime.utc_now(), stage_outcome: :done, error: nil}) |> Repo.update()

    broadcast_pipeline_changed(run.task)
    {:ok, finished}
  end

  # A new round's Send asks for its plan, which replaces the last round's.
  defp resume(%Run{} = run, sent, round) do
    comments = numbered(sent, 1, run.task)
    note = note(sent, comments, round, run.task)

    fix_plan = %FixPlan{
      round: round,
      findings: Enum.map(sent.fix, &%FixPlan.Finding{key: &1.key, title: &1.title}),
      comments: Enum.map(comments, &elem(&1, 0))
    }

    start(run, note, sent, sent.fix, {fix_plan, Pipeline.read_fix_plan(run.task)})
  end

  # What changed since the round's last Send goes, and the round's plan now has to cover it.
  defp revise(%Run{} = run, %FixPlan{} = waiting, sent, changes) do
    known = MapSet.new(waiting.findings, & &1.key)
    added = Enum.reject(sent.fix, &MapSet.member?(known, &1.key))
    comments = numbered(sent, length(waiting.comments) + 1, run.task)
    note = revision_note(waiting, changes, added, comments, run.task)

    fix_plan = %{
      waiting
      | findings: Enum.map(sent.fix, &%FixPlan.Finding{key: &1.key, title: &1.title}),
        comments: waiting.comments ++ Enum.map(comments, &elem(&1, 0))
    }

    start(run, note, sent, added, {fix_plan, waiting})
  end

  # The note is consumed by the spawn and never written anywhere, so the conversation keeps it too. The run reads
  # running from here, and only one of two Sends racing for it moves it there, so only one spawns.
  defp start(%Run{} = run, note, sent, learned, {fix_plan, before}) do
    {:ok, role} = Roles.get_role(id: run.role_id)

    with {1, [reopened]} <- reopen_review_run(run, note),
         :ok <- write_fix_plan(run.task, fix_plan),
         send_back(run.task, :review_lead, note),
         {:ok, os_process} <- Pipeline.start_review_run(%{reopened | task: run.task, role: role}) do
      # Learned only once the note is delivered, since a ruling can still change before the next Send.
      {overrides, corrections} = Enum.split_with(learned, &is_binary(&1.suppressed_by_id))
      {:ok, _flagged} = Learnings.record_overrides(run.task, overrides)
      {:ok, _learned} = Learnings.record_corrections(run.task, corrections ++ sent.finding ++ sent.diff ++ sent.screen)
      sent(run.task, sent, os_process.run)
    else
      {0, []} ->
        unsend(sent)
        {:error, :stage_running}

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        put_back(run.task, before)
        spawn_failed(run.task, sent, failed)

      {:error, :dispatch_disabled} ->
        put_back(run.task, before)
        unstarted(run, sent, :dispatch_disabled)
    end
  end

  # Nothing was delivered, so the round's plan reads as it did before the Send.
  defp put_back(%Task{} = task, nil), do: File.rm!(fix_plan_path(task))
  defp put_back(%Task{} = task, %FixPlan{} = before), do: write_fix_plan(task, before)

  defp fix_plan_path(%Task{issue: issue} = task),
    do: Path.join([task.scratch_path, "fix_plans", "#{issue.identifier}.json"])

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

  # Each comment in send order, numbered on from `first`: what the fix plan keeps of it, and its block for the note.
  defp numbered(%{finding: finding, diff: diff, screen: screen}, first, %Task{} = task) do
    screens = if screen == [], do: [], else: Pipeline.list_screens(task)

    comments =
      Enum.map(finding, &{:finding, "On a finding", "#{&1.finding.key} · #{&1.label}", &1}) ++
        Enum.map(diff, &{:diff, "On the diff", "#{Path.basename(&1.path)}:#{&1.line}", &1}) ++
        Enum.map(screen, &{:screen, "On a screen", &1.label, &1})

    comments
    |> Enum.with_index(first)
    |> Enum.map(fn {{kind, on, place, comment}, n} ->
      {%FixPlan.Comment{number: n, kind: kind, place: place, text: comment.body},
       "#{n}. #{on}:\n#{block(comment, screens, task.scratch_path)}"}
    end)
  end

  defp block(%FindingComment{} = comment, _screens, _scratch_path), do: FindingComment.calculate_block(comment)
  defp block(%DiffComment{} = comment, _screens, _scratch_path), do: DiffComment.calculate_block(comment)

  defp block(%ScreenComment{} = comment, screens, scratch_path),
    do: ScreenComment.calculate_block(comment, Enum.find(screens, &(&1.key == comment.key)), scratch_path)

  defp note(%{fix: fix}, comments, round, %Task{}) do
    sections = [
      sent_line([{length(fix), "finding"}, {length(comments), "comment"}]),
      opening(fix, comments, round),
      Enum.map(fix, &finding/1),
      Enum.map(comments, &elem(&1, 1)),
      comments != [] && @comment_rules,
      @plan_steps
    ]

    join(sections)
  end

  defp revision_note(%FixPlan{round: round}, changes, added, comments, %Task{}) do
    rulings =
      Enum.map(changes, fn change ->
        ~s(<ruling_change key="#{change.key}" was="#{ruling(change.was)}" now="#{ruling(change.now)}">\n#{change.title}\n</ruling_change>)
      end)

    sections = [
      sent_line([{length(changes), "changed ruling"}, {length(comments), "comment"}]),
      "The human changed fix round #{round} while its plan waited on approval. #{@revise_steps}",
      rulings != [] && "These rulings changed since the last Send. Leave a finding no longer ruled Fix out of the plan:",
      rulings,
      added != [] && "Now ruled Fix, whole:",
      Enum.map(added, &finding/1),
      comments != [] && "New comments, numbered on from the round's:",
      Enum.map(comments, &elem(&1, 1)),
      comments != [] && @comment_rules
    ]

    join(sections)
  end

  defp join(sections), do: (sections |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.join("\n\n")) <> "\n"

  # The line the conversation reads a Send back from.
  defp sent_line(parts) do
    said = for {count, word} <- parts, count > 0, do: if(count == 1, do: "1 #{word}", else: "#{count} #{word}s")

    case said do
      [one] -> "Sent #{one}."
      many -> "Sent #{Enum.join(Enum.drop(many, -1), ", ")} and #{List.last(many)}."
    end
  end

  defp ruling(:fix), do: "Fix"
  defp ruling(:skip), do: "Don't fix"

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
