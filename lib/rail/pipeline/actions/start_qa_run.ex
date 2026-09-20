defmodule Rail.Pipeline.Actions.StartQaRun do
  @moduledoc """
  Spawns the QA stage's run: the brief naming the change to exercise and the one
  file the findings go in, and the process that writes it.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only QA knows about.

  A task reaches QA more than once, so the brief is not the same every time: the
  findings already on the task go into it with what the human decided about each,
  and the pass is then a re-test of those as well as a reading of whatever has
  changed since.
  """

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Spawns `run`'s role to QA its task.

  The run is the whole handle: it carries the task to exercise, the worktree to
  run it in, and the role that does it. Returns whatever
  `Tools.start_os_process/2` does.
  """
  def start_qa_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]])
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "evidence"]))

    prompt =
      Pipeline.build_prompt(
        task: task,
        backend: role.backend,
        role_instructions: role.system_prompt,
        context_snippet: brief(task),
        pending_answer: run.pending_answer,
        conversation_id: run.conversation_id
      )

    args =
      Tools.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: role.system_prompt,
        conversation_id: run.conversation_id,
        work_dir: task.worktree_path
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{scratch_path: scratch_path, issue: %Issue{} = issue} = task) do
    dir = Path.join(scratch_path, "qa")
    file = Path.join(dir, "#{issue.identifier}.json")
    evidence = Path.join(dir, "evidence")

    String.trim("""
    QA the change described below by driving the running application. #{workspace(task)}

    You are testing it, not changing it: write no application code and no tests, fix nothing you find, and never run a git command that writes - no commit, no push, no branch, no checkout, no stash. Reading the tree with git is how you know what changed.

    Nothing under #{scratch_path} is part of the change. It is your workspace, and Rail keeps it out of the commit.

    The browser is Rail's rather than yours. `qa_goto`, `qa_do`, `qa_look`, `qa_shot` and `qa_problems` drive one headless Chrome that stays where you left it between calls; it opens on the first call and Rail closes it when the task moves on, so there is nothing to start and nothing to stop.

    Drive by outcome. `qa_do` takes what you want to be true of the page - "a bill for Sysco dated 12 Aug 2026 for $2,500 is entered and saved" - with every value it needs in `values`, keyed by the field's label, and it loops until it gets there. A keystroke at a time is slower and worse: each call begins knowing nothing of the last, so the same step gets chosen twice. Then read the page with `qa_look` before you mark the check: reaching the end of an instruction is not the same as the application having done the right thing, and the check is about the second.

    Before you open anything, call `qa_plan` with every check this pass will run, each under a `group` that says what kind of check it is - the setup you had to do to reach the change reads differently from the acceptance criteria. Every acceptance criterion on the ticket gets at least one check, quoting it in `criterion`: that mapping is how a reader knows the ticket was covered rather than the application poked at, and a criterion you cannot exercise is still a row - run it and mark it `skipped` with the reason. Call `qa_check` on each one the moment you have run it rather than at the end. A human watches that list fill in while you work - it is the only view they have of a pass in flight, and a pass that stops half way says which rows it never reached. The `check` field on a finding names the row it came out of, so the two have to agree.

    The checklist and the findings are one account, not two. Every finding names the row it came out of, and a row you raised a finding against did not pass: mark it `fail`. If what you found belongs to no row you planned - a defect you walked past on the way to something else - call `qa_plan` again with that row added and then mark it, rather than leaving the list saying everything was fine. The only finding that leaves a row `pass` is one that was already broken before this change (`caused_by_change: false`), and the row's note has to say so. A checklist of twenty passes over a report of six findings is a pass nobody can believe.

    Every picture is filed against a check: `qa_shot` takes the row's key as well as a caption, and the human reads the checklist a row at a time with the pictures taken for it. Take at least one for every check, at the moment it asserts something - a row with no picture is a row they have only your word for.

    Writing #{file} is how you report, and it is the last thing you do. Write it from your worktree with a heredoc, the body and its closing JSON line at column zero:

    mkdir -p #{dir}
    cat > #{file} <<'JSON'
    {
      "verdict": "fail",
      "summary": "one or two sentences: whether the change works, and the one thing most in the way if it does not",
      "not_checked": "what you could not check, and why",
      "findings": [
        {
          "key": "short-stable-slug",
          "title": "one line naming the defect",
          "check": "the key of the checklist row this came out of",
          "criterion": "the acceptance criterion it fails, quoted",
          "screen": "/bills/new",
          "steps": "1. ...\\n2. ...",
          "expected": "what should have happened",
          "observed": "what happened",
          "detail": "what it costs and who it costs it",
          "suggestion": "the change that settles it",
          "severity": "major",
          "recommendation": "fix",
          "caused_by_change": true,
          "status": "open",
          "evidence": [
            {"name": "the error rendering white", "kind": "screenshot", "path": "evidence/bill-new-error.png"}
          ]
        }
      ]
    }
    JSON

    - A heredoc into #{file}, never an inline string. Write the whole file every pass; it is the complete report, not a list of what is new.
    - `summary` is one or two sentences and sits above everything else a human reads, so it is the headline and not the report. Whether the change works, and the single thing most in the way if it does not. No list of the findings - they are listed underneath it - and no recap of what you drove.
    - `verdict` is `pass`, `concerns` or `fail`, and it is your judgement rather than a tally of what is below it. Three majors that were all broken before this change is a `pass`. One minor that makes the feature unusable is a `fail`. A human reads it beside the findings and decides what to do, so it gates nothing - say what you actually think.
    - One finding per defect. Two symptoms of one cause are one finding; one screen with three unrelated defects is three.
    - `key` is your own name for the defect, lowercase with hyphens, and it must stay the same for the same defect across passes. That is what lets a later pass update a finding rather than raise it twice.
    - `check` is the `key` of the checklist row it came out of, exactly as you wrote it in `qa_plan`, and it is required: a finding nobody can re-run is a finding nobody can close. The key rather than the title is what lets Rail put the pictures you filed for that row next to the finding, so a defect a reader can see is one you have already photographed. `criterion` is the ticket's own wording where one covers it, and nothing when you were looking around rather than verifying.
    - `severity` is `blocker`, `major`, `minor` or `nit`, and says how much the defect matters. `recommendation` is `fix` or `skip`, and says whether you would act on it on this branch. They are separate axes: a nit worth the thirty seconds it costs is `fix`, and a blocker is never `skip`.
    - `caused_by_change` is `false` for something that was already broken before this branch. Report those - finding them is half the job - but they are rarely this branch's to fix, and saying so is what stops the engineer chasing them.
    - `suggestion` is written as though the finding will be fixed, because by the time an engineer reads it a human has decided it will be. It is one change, named concretely enough to apply. Nothing in it restates or reconsiders `recommendation`: "leave it", or a fix offered as one branch of a choice, hands the engineer a decision the human has already taken.
    - `steps`, `expected` and `observed` are what the engineer reproduces from. A defect it cannot see is a defect it will argue with rather than fix.
    - Evidence is how a reader knows you saw it rather than reasoned it. Anything visible gets a picture: take it while you are looking at the defect, and name the same check on the finding. A screenshot comes from `qa_shot`, which files it under the check you named and hands back the name to put in `path` - do not invent one, and do not write a picture yourself. `qa_shot` gives you the name and not the picture: read one with the Read tool when a check turns on how something looks, and cite the name without reading it when it does not. A picture you read is in your context for the rest of the pass, and the human opens it from the finding either way. Anything else you captured goes into #{evidence} with a `path` relative to #{dir}, never absolute and never climbing out with `..`, or Rail drops it and nobody sees it. `kind` is `screenshot`, `log`, `query` or `note`; something small enough to read inline goes in `text` instead of a file.
    - `status` is `open` for a defect that still stands. Leave findings out entirely rather than inventing them: `{"findings": []}` with a `pass` verdict is a clean QA pass and is the right answer when the change works.
    - Report only what you exercised. A finding you could have reproduced and did not is a guess, and a guess costs the engineer a whole round.
    - Write the file only once the pass is finished. If you stop part way, for a question or anything else, leave the file unwritten and the task waits for you.
    - Ask everything at once. Research to the end before you stop, then put every question you could not close in that one message, each `[QUESTION: ...]` on a line of its own. Rail collects them and the human answers the lot in a single pass, so one question at a time costs them a round trip each. A question you can settle from the app, the ticket or the plan is not a question.

    #{outstanding(task)}
    #{plan(task)}
    The ticket the change was built from. Its acceptance criteria are the first source of your checklist:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  defp workspace(%Task{worktree_path: worktree_path, worktree_name: branch, project: %Project{} = project}) do
    String.trim("""
    Your worktree is #{worktree_path} and every path you touch is under it. The change is the branch #{branch} against #{project.default_branch} on remote `origin`: read it with `git diff origin/#{project.default_branch}...HEAD` from your worktree. Other agents share this repository, so never work in the main checkout and never touch another worktree.
    """)
  end

  # A task comes back to QA once the engineer has fixed and the reviewer has read
  # it again. What QA is owed is a verdict on each thing it already raised, so the
  # rows are handed back to it rather than left for it to remember.
  defp outstanding(%Task{} = task) do
    case Pipeline.list_qa_findings(task) do
      [] ->
        ""

      findings ->
        """
        This change has been QA'd before and has been round the engineer and the reviewer since. These are the findings already on it, and this pass owes a verdict on every one of them.

        #{Enum.map_join(findings, "\n", &finding_line/1)}

        Re-run the check each one came from and restate its key in the file you write, with `status` set to `fixed` where the application now behaves and `not_fixed` where it does not, and say in `detail` what you actually drove. Keep a dismissed finding listed with the `status` it has and never argue it again - the human has ruled on it. Anything new you find in the application as it now stands is a new finding with a new key, and is welcome.
        """
    end
  end

  defp finding_line(%QaFinding{} = finding) do
    origin = if QaFinding.regression?(finding), do: "this change", else: "pre-existing"
    screen = if finding.screen, do: " (#{finding.screen})", else: ""

    "- `#{finding.key}` [#{finding.severity}, #{origin}, human decided: #{decision_word(finding.decision)}, status: #{finding.status}] #{finding.title}#{screen}"
  end

  defp decision_word(:fix), do: "fix it"
  defp decision_word(:skip), do: "dismissed, leave it"
  defp decision_word(nil), do: "not yet decided"

  # A task that skipped architect has no plan, and the ticket is then the whole
  # of the specification the application is exercised against.
  defp plan(%Task{} = task) do
    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content}} ->
        "The approved implementation plan the change was built from. What it named is what should now work, and a screen it called for that does not exist is a finding however clean the code is.\n\n#{String.trim(content)}\n"

      {:error, :not_found} ->
        "There is no implementation plan for this ticket, so the ticket below is the whole specification.\n"
    end
  end
end
