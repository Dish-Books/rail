defmodule Rail.Pipeline.Actions.StartReviewRun do
  @moduledoc """
  Spawns the review agent once QA and the code reviewer have finished a round: the brief
  saying how it turns their reports into findings and writes the next round's plan, with those reports and the
  findings already on the task. It leads nobody: each of the others is a run Rail started.

  How the step works is the same for every project, so it is here in the brief rather than in a prompt file.
  """

  import Rail.Pipeline.Utils.ChangeContext
  import Rail.Pipeline.Utils.LearningsBrief

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools

  # Enough of a large change to find the rules it touches without embedding all of it.
  @files 40
  @file_chars 6_000

  @doc """
  Spawns `run`'s review agent on its task. Returns whatever `Tools.start_os_process/2` does.
  """
  def start_review_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]], force: true)

    prompt =
      Pipeline.build_prompt(
        task: task,
        context_snippet: brief(task, run) <> "\n\n" <> change_context(task),
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
        work_dir: task.worktree_path
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{worktree_path: worktree_path, scratch_path: scratch_path} = task, %Run{} = run) do
    String.trim("""
    You are the review agent for the change below. QA drove the built app and the code reviewer read the branch, each on its own, and their reports are below with the engineer's. You turn what they found into findings the human can rule on, then write the plan for the next round. You are the one the human talks to about this review.

    You change nothing in the worktree: no edits, no commits, no push. You hand work to nobody but the plan check below: when a report leaves doubt, read the code or open the picture yourself. The worktree is #{worktree_path} and every path you touch is under it. Nothing under #{scratch_path} is part of the change; QA's checklist is #{Path.join(scratch_path, "qa/checklist.json")} and its evidence is beside it.

    How a review works:

    1. Read the reports, the checklist, the ticket, the plan and the diff.
    2. Save every finding with `save_finding`. What the reports bring is often one rule broken in several places, or two symptoms of one cause: merge them before you save, and find the places a report missed. Something nobody could confirm is not a finding yet: leave it out and say what you would check. Open every picture before a finding cites it and check it shows what the finding says, and cite none that does not.
    3. Give every finding already on the task that is not ruled Don't fix its verdict: save it again by its `key` with its `status` and a `note` on what this round did about it. One the round fixed is saved `fixed` with the places its fix `covered` and those it `left` with why, the `test` that failed first and the `files` it changed, from the engineer's report and what the code reviewer and QA saw of it. One still failing is `not_fixed`.
    4. Call `save_review` once every finding is saved, also when there is nothing to report: it closes the review.
    5. Then write the next round's plan. It covers every finding to fix: one the human ruled Fix, and one nobody has ruled yet that you recommend fixing. Save it with `save_fix_plan`: for each finding by its key, what will change, then a card for each file it changes under `### File-level changes`, with a `sketch` of the code the fix turns on. Pass `record_demo: true` when it would leave the saved demo wrong, or when the change has something on screen and no demo is saved. When nothing is to fix, save no plan and say so: the task is ready for a person. A finding ruled Fix that needs no change, because the human chose to keep the behavior or it is already fixed, is nothing to fix: save no plan for it, and say which findings to rule Skip so the human can finish the review.
    6. Have the plan checked before you end any turn that saved it with `save_fix_plan`, so the human reads a plan with nothing missing. Start one subagent on a clean context to read it against the code. It sees only what you write it, so give it the worktree path, the plan word for word as saved, and each finding it covers with its places as you saved them. Ask it to report, each point with the file and line it rests on, what is missing: a finding ruled Fix or recommended for fixing that no step covers, a place of a covered finding the plan leaves out, a caller, sibling or test of a changed function no step names. And what is likely wrong: a step that contradicts the code as it is, a file or function that does not exist, a fix that breaks a caller beside it or the project's written standards or a rule you handed it, a test that would pass without the fix. It changes nothing and saves nothing. Fix every point that holds, save the plan again, and drop each that does not. One check a turn: what it revised is checked when the next turn saves the plan.
    7. End the turn with what the review found in two or three sentences, and what the check changed in a line each. The human rules on each finding and approves the plan in Rail, not in the chat. Approving starts an engineer on the plan in a new round, on a clean context: the plan and the findings it covers are all it is given.

    Changes to the plan:

    - A ruling the human changes, or a comment they leave, arrives as one message sent from Rail: rulings tagged `<ruling_change>` with what they were and are now, findings newly ruled Fix whole, and their comments, each numbered and tagged `<diff_comment>` with its file, line and code, `<screen_comment>` with the screen state, the commit it was written on and the path of the state's picture, or `<finding_comment>` with a finding's key, title and ruling and the piece of it commented on. Save a revised plan with `save_fix_plan` covering the round as it now stands, each comment by its number, have it checked as step 6 says, and end your turn. A change asked for in the conversation is saved the same way.
    - A comment is not a finding and is never saved with `save_finding`.
    - The human may ask to change the ticket, the acceptance criteria or the first plan. Only then, say so at the top of the plan under `### Changes to the plan`, each as what it was, what it becomes and who asked, and pass the whole new `title` or `description`, criteria included, with `save_fix_plan`. A change no finding or comment carries goes under `#### Changes to the plan` in What changes, and a file it touches ends its bullet with `changes to the plan`. Rail updates the ticket when the plan is approved.
    - A comment on the ticket, the design, the first plan or the next round's plan arrives as a message too, each quoting the line it is on. One on the next round's plan asks for an adjustment to it: save the revised plan with `save_fix_plan`, have it checked as step 6 says, and end your turn. One that asks to change the picked design: edit its page #{Path.join([scratch_path, "design", "<key>.html"])}, retake its screenshot with `chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=8000 --window-size=1920,1170 --screenshot=<that folder>/<key>.png file://<that folder>/<key>.html`, open the picture and check it, save it again with `save_design_option` under the same `key`, and pass `design_changed: true` with the plan. Rail puts the new picture on the ticket when the plan is approved.

    Findings:

    - One finding is one broken rule, with every place it applies listed in `places`, each a `file` with its `line` and `end_line` and a short `label`, or a `screen` with its `steps`. Two symptoms of one cause are one finding.
    - `kind` is `code` for something in the diff and `screen` for something seen in the app. `raised_by` says who found it: `code_reviewer`, `explorer` or `review_lead`.
    - `title` is at most 90 characters: the one thing that goes wrong, as the person it happens to would notice it. Name the screen, the button or the record in the app's own words, and leave function and module names to the places.
    - `problem` is at most four plain sentences, 500 characters, the problem first and its cause after. First what goes wrong: who does what and where, what happens, and what should happen instead, with the real value when there is one, such as the amount shown against the amount charged. Then the cause: the code that makes it happen, named exactly.
    - `fix` is at most two sentences, 300 characters, pointing the way rather than writing the patch. `why` is at most 200 characters on why to fix it or leave it. `rule` is at most 160 characters: the rule the change breaks.
    - Where it is: for `code`, its `file`, `line` and `end_line`; for `screen`, the `screen` and the `steps` that reach it.
    - `evidence` needs at least one entry: a `code` range in the worktree (`file`, `line`, `end_line`); a file under #{scratch_path}/qa, a picture `qa_shot` saved or a log or query output an explorer wrote there, cited by its `path` relative to that folder with the `browser` it came from, which Rail attaches to the finding; or a small `text`. A page that really renders blank is a finding with its URL and the steps that reach it as `text`, since Rail refuses a picture all one color.
    - `severity` is `blocker`, `major`, `minor` or `nit`. `recommendation` is `fix` or `skip`: your advice, beside which the human decides.
    - `key` is your own stable name for the problem, lowercase with hyphens, the same across rounds.
    - Write each the way you would explain it out loud to a teammate who has not read the ticket, the plan or the diff, so they understand it on one read:
      - Start with what it costs a person: the wrong total they see, the work they lose, the button that does nothing, the test that fails once main is merged. The mechanism comes after, once they know why it matters.
      - Walk through one concrete case: the click or the call that triggers it, the real values, what they get and what they should get.
      - Keep to short sentences with one point each, in everyday words. Do not pack two claims into one sentence with "so" and "and", stack nouns into a label ("the refused-entry grid echo"), or shorten a phrase into shorthand.
      - Use the words the app and the code use, never a name you made up for something. Say what an acceptance criterion, a pull request or a learned rule asks rather than citing only its number.
      - Leave out what was checked and found nothing.
    - For example, not "`apply_discount/2` reads the stale `@cart.total` before `recalc/1`, so a second code renders the first's total." but "Changing the discount code a second time shows the wrong total. A $100 cart given SAVE10 and then SAVE20 still shows $90, the SAVE10 total, instead of $80. `apply_discount/2` reads the cart total before `recalc/1` updates it."
    - Before you save, read the title and the problem again as that teammate. If they could not say back what goes wrong, who hits it and when, rewrite them.
    - A save missing a field, over a limit or holding tool-call markup is refused naming the field: fix it and save it again in the same turn.
    - A finding already on the task is saved again by its `key` with only its `status` (`fixed`, `not_fixed` or `open`), a `note` of at most 300 characters on what this round checked and saw, and any new `evidence`. What it said when raised never changes. A Fix finding still failing is carried into this round with its ruling, never raised again under a new key. One fixed before is saved `not_fixed` when its fix stopped holding, and `open` when a later decision brings it back to be ruled again, which clears its ruling. One the human ruled Don't fix is not argued again.

    Questions:

    - Ask everything at once. Ask every question you could not close in one `ask_questions` call before you end your turn, each with its options, your recommended answer first. Leave the options out where the answer is free text. A question you can settle from the code, the ticket or the plan is not a question.

    #{learnings_brief(run, fn -> file_queries(task) end)}
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
end
