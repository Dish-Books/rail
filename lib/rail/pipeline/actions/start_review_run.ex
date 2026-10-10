defmodule Rail.Pipeline.Actions.StartReviewRun do
  @moduledoc """
  Spawns the Review lead: the brief saying how a round and a fix round work, the findings already on the
  task, and the process that leads the code reviewer, QA explorers, engineer and demo recorder as subagents.

  How the step works is the same for every project, so it is here in the brief rather than in a prompt
  file. `enter_stage/3` has already claimed the stage, started the run and made the worktree.
  """

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.LearningsBrief
  import Rail.Pipeline.Utils.PrepareTurn
  import Rail.Pipeline.Utils.ReviewSubagents
  import Rail.Pipeline.Utils.TicketTrailer

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools

  # Enough of a large change to find the rules it touches without embedding all of it.
  @files 40
  @file_chars 6_000

  @doc """
  Spawns `run`'s Review lead on its task, with its subagents. Returns whatever `Tools.start_os_process/2` does.
  """
  def start_review_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]], force: true)
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "evidence"]))
    File.mkdir_p!(Path.join(task.scratch_path, "demo"))
    :ok = prepare_turn(%{run | task: task})

    prompt =
      Pipeline.build_prompt(
        task: task,
        context_snippet: brief(task, run),
        pending_answer: run.pending_answer,
        conversation_id: run.conversation_id
      )

    args =
      Tools.build_args(
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: role.system_prompt,
        conversation_id: run.conversation_id,
        work_dir: task.worktree_path,
        agents: review_subagents(task)
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{scratch_path: scratch_path, issue: %Issue{} = issue} = task, %Run{} = run) do
    String.trim("""
    You lead Rail's Review step for the change below: one run that reads the code, drives the built app and records the demo, and, once the human has ruled on what it found, has the fixes they ruled Fix made, a round at a time. The code reviewer, the QA explorers, the engineer and the demo recorder are your subagents: hand each its work with the Task tool, naming it, and start an explorer's description with its browser name, as in `explorer-1: Checks 1 and 2`. A subagent sees only what you write it. #{workspace(task)}

    You change nothing in the worktree yourself: the engineer makes and commits every change, committing as the ticket's owner, which Rail sets for each turn, and ending each commit message with the line `#{ticket_trailer(issue)}`, which you hand it. Nobody pushes: a turn that ends with commits the remote does not have yet hands them to Rail, which runs CI, pushes them and starts the next round. Work left uncommitted is not sent on. Nothing under #{scratch_path} is part of the change.

    At the start of every turn, check the branch against `origin/#{task.project.default_branch}`, which Rail fetched as the turn started. When it is behind, have the engineer bring it up to date by merge or rebase, as suits the change, resolve every conflict the way both sides meant it, and commit; have the code reviewer read what came in against what the branch relies on, and the engineer follow it through the branch's code, tests and comments.

    How a round works:

    1. Read the ticket, the plan and the diff, then write the checklist with `qa_plan`: every acceptance criterion gets at least one check quoting it in `criterion`. Name every screen state the change affects, each with a lowercase hyphenated `key` you keep for the whole review and a label saying what it shows, such as `file-list-after-send`, "File list just after Send".
    2. Have one explorer start the app server first, from the worktree, and tell you its address. Hand the other explorers their checks once it is up.
    3. Then, in parallel: the code reviewer reads the branch against the plan and the ticket. The explorers, one per group of one or two checks, each drive the app in a browser of its own named `explorer-1`, `explorer-2` and so on, take `save_screen` of each screen state you hand them by its key and label, and bring back what they saw with its evidence. Every round, the first included, every affected screen state is shot again, so the human sees each one on the latest commit. The demo recorder, when the change has something on screen, records a shot list you write from the acceptance criteria, in the browser named `demo`, beside them; it never holds up the round. A change with nothing on screen gets no demo: say so in one line.
    4. Nothing reaches the human before the code reviewer and every explorer have finished. Then settle each check with `qa_check` from what the explorers saw, and save every finding with `save_finding` yourself. A subagent never saves a finding or marks a check. What the subagents bring back is often one rule broken in several places, or two symptoms of one cause: merge them before you save, and send the code reviewer back for the places it missed. Something nobody could confirm is not a finding yet: have the subagent that saw it reproduce it, or leave it out and say what you would check.
    5. Call `save_review` last, also when there is nothing to report: it closes the round. End the turn with what the round found in two or three sentences. The human rules on each finding in Rail, not in the chat.

    Findings:

    - One finding is one broken rule, with every place it applies listed in `places`, each a `file` with its `line` and `end_line` and a short `label`, or a `screen` with its `steps`. Two symptoms of one cause are one finding.
    - `kind` is `code` for something in the diff and `screen` for something seen in the app. `raised_by` says who found it: `code_reviewer`, `explorer` or `review_lead`.
    - `title` is at most 90 characters, written as what is wrong. `problem` is at most two plain sentences, 300 characters. `fix` is at most two sentences, 300 characters, pointing the way rather than writing the patch. `why` is at most 200 characters on why to fix it or leave it. `rule` is at most 160 characters: the rule the change breaks.
    - Where it is: for `code`, its `file`, `line` and `end_line`; for `screen`, the `screen` and the `steps` that reach it.
    - `evidence` needs at least one entry: a `code` range in the worktree (`file`, `line`, `end_line`); a file under #{scratch_path}/qa, a picture `qa_shot` saved or a log or query output an explorer wrote there, cited by its `path` relative to that folder with the `browser` it came from, which Rail attaches to the finding; or a small `text`.
    - `severity` is `blocker`, `major`, `minor` or `nit`. `recommendation` is `fix` or `skip`: your advice, beside which the human decides.
    - `key` is your own stable name for the problem, lowercase with hyphens, the same across rounds.
    - Write each for someone who reads it once: the code or the screen named exactly, and no list of what was checked and found nothing.
    - A save missing a field, over a limit or holding tool-call markup is refused naming the field: fix it and save it again in the same turn.
    - A finding already on the task is saved again by its `key` with only its `status` (`fixed`, `not_fixed` or `open`), a `note` of at most 300 characters on what this round checked and saw, and any new `evidence`. What it said when raised never changes. A Fix finding still failing is carried into this round with its ruling, never raised again under a new key. One the human ruled Don't fix is not argued again.

    A fix round:

    1. Start fix round arrives as a message listing the findings the human ruled Fix, with their rules and places. Hand them to the engineer whole, every place included.
    2. When the engineer reports, have the code reviewer read the uncommitted diff against those findings, and an explorer re-check any screen a fix touched, before anything is committed. Send what they find back to the engineer.
    3. Have the engineer commit the fixes. Save each Fix finding with `save_finding`, `status` fixed, the places its fix `covered` and those it `left` with why, the `test` that failed first and the `files` it changed. It refuses a report that leaves a place unaccounted for or has no test: settle what it names and save it again. In your last message, give every other changed file, one no finding asked for, with its reason, which the human reads. End your turn: Rail runs CI on the commits, pushes them and starts the next round once CI passes. A turn that committed while a Fix finding is not saved fixed is held, and nothing is sent on until it is.
    4. When CI fails, Rail resumes you with its output: have the engineer fix it and commit, or end your turn with nothing changed to run CI again when the failure is not the change's.

    Questions:

    - Ask everything at once. Put every question you and the subagents could not close in your last message, each on a line of its own as `[QUESTION: ...] [OPTIONS: <recommended> | <other>]`, your recommended answer first and the options split by `|`. Leave out `[OPTIONS: ...]` where the answer is free text. A question you can settle from the code, the ticket or the plan is not a question.

    #{outstanding(task)}
    #{plan(task)}#{learnings_brief(run, fn -> file_queries(task) end)}
    The ticket the change was built from. Its acceptance criteria are the first source of the checklist:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  # One query per changed file, its changed lines, so each finds the rules about that kind of code.
  defp file_queries(%Task{} = task) do
    case Git.load_diff(Scope.for_system(), task, :branch) do
      {:ok, files} ->
        for file <- Enum.take(files, @files) do
          changed = for %{kind: :line, line_kind: kind, text: text} <- file.rows, kind != :context, do: text
          {file.path, changed |> Enum.join("\n") |> String.slice(0, @file_chars)}
        end

      {:error, :no_worktree} ->
        []
    end
  end

  defp workspace(%Task{worktree_path: worktree_path, worktree_name: branch, project: %Project{} = project}) do
    String.trim("""
    The worktree is #{worktree_path} and every path you and the subagents touch is under it. The change is the branch #{branch} against #{project.default_branch} on remote `origin`: read it with `git diff origin/#{project.default_branch}...HEAD`, and when main has been merged in, read the branch's own commits with `git log --first-parent --no-merges`. Other agents share this repository, so never work in the main checkout and never touch another worktree.
    """)
  end

  # The findings already on the task are handed back rather than left for the lead to remember.
  defp outstanding(%Task{} = task) do
    case Pipeline.list_findings(task) do
      [] ->
        ""

      findings ->
        """
        These findings are already on the task, newest round first, with what the human ruled and what has happened to each. A round owes a verdict on every one not ruled Don't fix.

        #{Enum.map_join(findings, "\n", &finding_lines/1)}
        """
    end
  end

  defp finding_lines(%Finding{} = finding) do
    round = if finding.carried_round, do: "carried into round #{finding.carried_round}", else: "round #{finding.round}"
    fixed = if finding.fixed_in, do: ", fixed in #{String.slice(finding.fixed_in, 0, 7)}", else: ""

    head =
      "- `#{finding.key}` [#{round}, #{finding.severity} #{finding.kind}, human ruled: #{ruling(finding)}, " <>
        "status: #{finding.status}#{fixed}] #{finding.title} (#{Finding.where(finding)})"

    places = finding.places |> Enum.with_index(1) |> Enum.map(fn {place, n} -> "  Place #{n}: #{place_line(place)}" end)
    notes = Enum.map(finding.notes, &"  #{note_line(&1)}")

    Enum.join([head | rule_line(finding) ++ places ++ notes], "\n")
  end

  defp rule_line(%Finding{rule: rule}) when is_binary(rule), do: ["  Rule: #{rule}"]
  defp rule_line(%Finding{}), do: []

  defp place_line(%FindingPlace{label: label} = place) when is_binary(label),
    do: "#{FindingPlace.describe(place)}, #{label}"

  defp place_line(%FindingPlace{} = place), do: FindingPlace.describe(place)

  defp note_line(%FindingNote{} = note) do
    words = if note.text, do: ": #{note.text}", else: ""
    commit = if note.commit, do: " on #{String.slice(note.commit, 0, 7)}", else: ""
    "Round #{note.round}, #{note_kind(note)}#{commit}#{words}"
  end

  defp note_kind(%FindingNote{kind: :ruling, decision: decision}), do: "ruled #{ruling_word(decision)}"
  defp note_kind(%FindingNote{kind: :pass, status: status}) when is_atom(status) and status != nil, do: "#{status}"
  defp note_kind(%FindingNote{kind: :fix}), do: "fixed"
  defp note_kind(%FindingNote{kind: kind}), do: to_string(kind)

  defp ruling(%Finding{decision: decision}), do: ruling_word(decision)

  defp ruling_word(:fix), do: "Fix"
  defp ruling_word(:skip), do: "Don't fix"
  defp ruling_word(nil), do: "not yet"

  # A task without a plan is read against its ticket alone.
  defp plan(%Task{} = task) do
    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content}} ->
        "The approved implementation plan the change was built from. It is the specification: where it named a file and what changed in it, that is what should have changed, and a change that did something else instead, or stopped short of it, is a finding however good the code is. Work beyond the plan is judged on whether it is right.\n\n#{String.trim(content)}\n"

      {:error, :not_found} ->
        "There is no implementation plan for this ticket, so the ticket below is the whole specification.\n"
    end
  end
end
