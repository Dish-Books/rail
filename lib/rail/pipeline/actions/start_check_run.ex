defmodule Rail.Pipeline.Actions.StartCheckRun do
  @moduledoc """
  Spawns one of the agents that check a round's change once it is pushed: QA, the code reviewer, the screenshots
  agent or the demo recorder. Each is a run of its own that Rail starts, on a clean conversation, with a brief
  saying how its part works. None of them changes the code or saves a finding: QA and the code reviewer save a
  report, and the review agent that follows them decides what is a finding.
  """

  import Rail.Pipeline.Utils.ChangeContext
  import Rail.Pipeline.Utils.LearningsBrief
  import Rail.Pipeline.Utils.RoundChange

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Spawns `run`'s role to check its task's change. Returns whatever `Tools.start_os_process/2` does.
  """
  def start_check_run(%Run{task: %Task{} = task, role: %Role{stage: stage} = role} = run)
      when stage in [:qa, :review, :screens, :demo] do
    task = Repo.preload(task, [:project, issue: [comments: :replies]], force: true)
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "evidence"]))
    File.mkdir_p!(Path.join(task.scratch_path, "demo"))

    prompt =
      Pipeline.build_prompt(
        task: task,
        context_snippet: String.trim(brief(stage, task, run)) <> "\n\n" <> change_context(task),
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

  defp brief(:qa, %Task{scratch_path: scratch_path} = task, %Run{} = run) do
    """
    You are QA for the change below: you test the running application and report what you saw. #{rules(task)}

    How your part works:

    1. #{checklist(task)}
    2. Start the app server from the worktree and drive the app in your browser. #{browser("qa")}
    3. Run each check and mark it with `qa_check` as soon as you have run it, with one line on what you saw. Take a picture with `qa_shot` at the point a check asserts something on screen. `qa_shot` saves it under #{Path.join(scratch_path, "qa")} and returns its path. Write a log, query output or any other file that proves a check there yourself.
    4. Re-check every finding below that is not ruled Don't fix and can be seen in the app, and say for each whether it still fails.
    5. Save your report with `save_report` before you end your turn. For each thing that looks wrong: what it is in one line, the steps that reach it, what you saw against what should happen, the path of every file that shows it with a line saying what it shows, and how bad you think it is. Then one line for each finding you re-checked. Something you could not confirm is not left out: say what you saw and what you would check. A pass that found nothing says so.
    6. Call `browser_close` as your last tool call, then end your turn in a sentence or two.

    - You never save a finding and never change a ruling: the review agent reads your report and decides.
    #{pictures()}
    - Keep scripts and data under #{scratch_path}, which survives between turns; `/tmp` does not. Keep the steps that reach each state as a script there, so a retake is one command.
    #{learnings_brief(run, [query(task)])}
    """
  end

  defp brief(:review, %Task{} = task, %Run{} = run) do
    """
    You are the code reviewer for the change below: you read it against its plan and its ticket and report what is wrong. #{rules(task)}

    How your part works:

    1. Read the plan, the ticket, the engineer's report when there is one, and the diff: the whole change, and this round's own change when one is named below, which is what the round's plan asked for. When the default branch has been merged in, read the branch's own commits with `git log --first-parent --no-merges`.
    2. Find what breaks a rule: of the plan, of the ticket's acceptance criteria, of the project's written standards, of the code around it. Find every place a rule applies before you report it: a guard missing in one handler is usually missing in its siblings.
    3. For every finding below that is not ruled Don't fix, read what the round did about it: whether every place it lists is covered or left with a reason that holds, and whether its test fails without the fix and checks the saved record or what the user sees. Then say what else the change touches that no finding asked for: a fix that is right in one place and breaks a caller beside it is a finding of its own.
    4. Save your report with `save_report` before you end your turn. Each proposed finding is one broken rule: a title of 90 characters or less saying what is wrong, the rule in one sentence, every place it applies as a file and its line range with a short label each, the problem in at most two plain sentences, a fix of at most two sentences that says where the change belongs rather than writing the patch, why to fix or leave it, a severity of blocker, major, minor or nit, and whether you would fix it. A rule broken in three files is one finding with three places, and two symptoms of one cause are one finding. Then one line for each existing finding you read. A read that found nothing says so.

    - You never save a finding and never change a ruling: the review agent reads your report and decides.
    #{learnings_brief(run, [query(task)])}
    """
  end

  defp brief(:screens, %Task{scratch_path: scratch_path} = task, %Run{} = run) do
    """
    You photograph every screen state the change below affects, so the human sees each one as the latest commit leaves it. #{rules(task)}

    How your part works:

    1. Read the ticket, the plan and the diff, and name every screen state the change affects. Each has a lowercase hyphenated `key` and a `label` saying what it shows, such as `file-list-after-send`, "File list just after Send". A change with nothing on screen has none: say so in one line and end your turn.
    2. #{known_screens(task)}
    3. Start the app server from the worktree and reach each state in your browser. #{browser("screens")}
    4. Take `save_screen` of each state once you have reached it. Every round every state is shot again, which replaces its last picture.
    5. Call `browser_close` as your last tool call, then end your turn with the states you saved and any you could not reach, and why.

    #{pictures()}
    - Keep the steps that reach each state as a script under #{scratch_path}, which survives between turns, so a retake is one command.
    #{learnings_brief(run, [query(task)])}
    """
  end

  defp brief(:demo, %Task{scratch_path: scratch_path} = task, %Run{} = run) do
    """
    You record the demo of the change below: one walkthrough in the running application that shows it doing what the ticket asks. #{rules(task)}

    How your part works:

    1. Write your shot list from the ticket's acceptance criteria: the fewest beats that show each one, in the order a person would meet them.
    2. Start the app server from the worktree and drive the app in your browser. #{browser("demo")}
    3. Drive the whole walkthrough once off camera to find out how it behaves, and put any data you changed back.
    4. Call `demo_start`, then follow the shot list in order. Say each beat with `demo_say` straight before you do it: one short plain sentence, naming the acceptance criterion in `criterion` when the beat proves one. Rail speaks each sentence aloud as the demo's voice-over, word for word, and holds the moment for as long as it takes to say, so write it in words only: no hyphens, slashes or other symbols, and no markup or paths.
    5. Call `save_demo` straight after the last beat: saving is what stops the recording and has Rail encode it, so nothing after it is filmed, and a demo never saved is never seen. A shot you could not get goes in `not_shown`.
    6. Call `browser_close` once `save_demo` has answered and never before it, since closing the browser ends the recording. End your turn with what the demo shows and anything broken you walked into.

    - A change with nothing on screen gets no demo: say so in one line and end your turn.
    - Keep the scripts that set up your starting state under #{scratch_path}, which survives between turns, so a retake is one command.
    #{learnings_brief(run, [query(task)])}
    """
  end

  defp rules(%Task{worktree_path: worktree_path, scratch_path: scratch_path}) do
    "You never change it: no edits, no tests written, and no commit, push, merge or rebase. Nobody relays for you and you hand work to nobody. The worktree is #{worktree_path} and every path you touch is under it. Other agents share this repository, so never work in the main checkout and never touch another worktree. Nothing under #{scratch_path} is part of the change."
  end

  defp browser(name) do
    "Call `browser_connect` for it: yours is named `#{name}`, signed in as its own fresh account, and is the one every browser tool uses when you name none. Other agents drive the same app from browsers of their own at the same time: check whether it already answers at its address before you start a server, and leave the server running when you finish."
  end

  defp pictures do
    String.trim("""
    - Read every picture you save before you rely on it. Write one line of what it shows first, then compare that line with its name or label: the screen, the state it is in and the width. Take one that does not match again, once: half loaded, a sign-in page, another screen or the wrong width.
    - Take a narrow picture by passing `width`, from 320 to 1920. A script's resize is gone once the script closes, and after a picture with a `width` the tab is back at its own width.
    - Rail refuses a picture all one color and saves nothing. A page that really renders blank is what you report, with its URL and the steps that reach it.
    """)
  end

  # A later round re-walks only what it can have changed: a full pass every round re-tests a merge's untouched flows.
  defp checklist(%Task{} = task) do
    case round_change(task) do
      %{number: number, merged: merged} ->
        touched =
          if merged,
            do: "what the merge changed in the files the branch had touched",
            else: "what the round's diff touches"

        "Read the ticket, the plan, the findings below and this round's own change, then write the checklist with `qa_plan`. This is round #{number}: the first round checked every acceptance criterion, so this pass checks what round #{number} changed. It has a check for each finding step 4 re-checks, checks for #{touched}, and a check quoting in `criterion` each acceptance criterion whose behavior that can reach. Run no check for a criterion it cannot reach, and say in your report, in one line for each area of criteria left out, why the round's change cannot reach it."

      nil ->
        "Read the ticket, the plan and the diff, then write the checklist with `qa_plan`: every acceptance criterion gets at least one check quoting it in `criterion`."
    end
  end

  # The states an earlier round shot keep their keys, so each one's pictures line up across commits.
  defp known_screens(%Task{} = task) do
    case Pipeline.list_screens(task) do
      [] ->
        "No state has been shot yet, so the keys are yours to choose; later rounds keep them."

      screens ->
        "These states were shot in an earlier round. Shoot each again under the same `key`, and add any the change now affects: " <>
          Enum.map_join(screens, "; ", &"`#{&1.key}` (#{&1.label})") <> "."
    end
  end

  defp query(%Task{issue: %Issue{} = issue}), do: "#{issue.title}\n\n#{issue.description}"
end
