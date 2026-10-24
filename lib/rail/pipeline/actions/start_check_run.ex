defmodule Rail.Pipeline.Actions.StartCheckRun do
  @moduledoc """
  Spawns one of the agents that check a round's change once it is pushed: QA, which also shoots the screen states
  the change has left out of date, the code reviewer or the demo recorder. Each is a run of its own that Rail starts, on
  a clean conversation, with a brief saying how its part works. None of them changes the code or saves a finding: QA and the code reviewer save a
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
      when stage in [:qa, :review, :demo] do
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
    2. Start the app server from the worktree and drive the app in your browser. #{browser("qa", scratch_path)}
    3. Run each check and mark it with `qa_check` as soon as you have run it, with one line on what you saw. Take a picture with `qa_shot` at the point a check asserts something on screen. `qa_shot` saves it under #{Path.join(scratch_path, "qa")} and returns its path. Write a log, query output or any other file that proves a check there yourself.
    4. #{screens(task)}
    5. Re-check every finding below that is not ruled Don't fix and can be seen in the app, and say for each whether it still fails.
    6. Save your report with `save_report` before you end your turn. For each thing that looks wrong: what goes wrong in one line, as the person using the screen would notice it, the steps that reach it, what you saw against what should happen, the path of every file that shows it with a line saying what it shows, and how bad you think it is. Write it the way you would tell a teammate who was not watching, in short sentences and everyday words, with the real values you saw. Then one line for each finding you re-checked, and the screen states you saved and any you could not reach, and why. Something you could not confirm is not left out: say what you saw and what you would check. A pass that found nothing says so.
    7. Call `browser_close` as your last tool call, then end your turn in a sentence or two.

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
    4. Save your report with `save_report` before you end your turn. Each proposed finding is one broken rule: a title of 90 characters or less saying the one thing that goes wrong, as the person it happens to would notice it, the rule in one sentence, every place it applies as a file and its line range with a short label each, the problem in at most four plain sentences, what goes wrong first (who does what and where, what happens, and what should happen instead) and then the code that causes it, a fix of at most two sentences that says where the change belongs rather than writing the patch, why to fix or leave it, a severity of blocker, major, minor or nit, and whether you would fix it. A rule broken in three files is one finding with three places, and two symptoms of one cause are one finding. Write each the way you would explain it out loud to a teammate who has not read the ticket or the diff: what it costs a person first, then one concrete case with its real values, in short sentences of one point each and everyday words, using the words the app and the code use and never a name you made up for something. Then one line for each existing finding you read. A read that found nothing says so.

    - You never save a finding and never change a ruling: the review agent reads your report and decides.
    #{learnings_brief(run, [query(task)])}
    """
  end

  defp brief(:demo, %Task{scratch_path: scratch_path} = task, %Run{} = run) do
    """
    You record the demo of the change below: one walkthrough in the running application that shows it doing what the ticket asks. #{rules(task)}

    How your part works:

    1. Write your shot list from the ticket's acceptance criteria: the fewest beats that show each one, in the order a person would meet them.
    2. Start the app server from the worktree and drive the app in your browser. #{browser("demo", scratch_path)}
    3. Drive the whole walkthrough once off camera to find out how it behaves, and put any data you changed back.
    4. Call `demo_start`, then follow the shot list in order. Say each beat with `demo_say` straight before you do it: one line, written as the bullets below say, naming the acceptance criterion in `criterion` when the beat proves one. Rail speaks each sentence aloud as the demo's voice-over, word for word, starting it as the action after it lands and cutting the wait between beats, so write it in words only: no hyphens, slashes or other symbols, and no markup or paths. Scroll with the driver's `scroll`, never `evaluate`: a scroll the page makes itself is not seen as the action its line describes. Before you seed data, switch user, reload or wait for the next beat, call `demo_cut`: the video leaves out what the page does from it to your next caption. Never call it between a caption and its action. Record at the tab's own size: never call `resize` once `demo_start` has answered, since the tab then paints at two sizes and the picture jumps.
    5. Call `save_demo` straight after the last beat: saving is what stops the recording and has Rail encode it, so nothing after it is filmed, and a demo never saved is never seen. A shot you could not get goes in `not_shown`. Write `summary` plainly, saying what the demo shows in the words of someone who has never seen the codebase: it is read as text, not spoken.
    6. Call `browser_close` once `save_demo` has answered and never before it, since closing the browser ends the recording. End your turn with what the demo shows and anything broken you walked into.

    - Each line is about twelve words, said aloud to the person watching beside you. It is a whole sentence with a verb and "I", "we" or "you", in the present tense, with contractions where they come naturally and "now" or "next" to move from one beat to the next. Talk to them about the screen, never describe it: "Now I'll pick Cash Main, and the bill updates", not "Picking Cash Main as the account updates the bill". They can see the clicking; what they can't see is why it matters.
    - The starting state you seeded is one beat at the front, said the same way, such as "Here's an order that's still waiting on payment", and then you move on.
    - A change with nothing on screen gets no demo: say so in one line and end your turn.
    - Keep the scripts that set up your starting state under #{scratch_path}, which survives between turns, so a retake is one command.
    #{learnings_brief(run, [query(task)])}
    """
  end

  defp rules(%Task{worktree_path: worktree_path, scratch_path: scratch_path}) do
    "You never change it: no edits, no tests written, and no commit, push, merge or rebase. Nobody relays for you and you hand work to nobody. The worktree is #{worktree_path} and every path you touch is under it. Other agents share this repository, so never work in the main checkout and never touch another worktree. Nothing under #{scratch_path} is part of the change."
  end

  # Bash has no background tasks here, and a server run in the foreground holds the command until its timeout.
  defp browser(name, scratch_path) do
    "Call `browser_connect` for it: yours is named `#{name}`, signed in as its own fresh account, and is the one every browser tool uses when you name none. Other agents drive the same app from browsers of their own at the same time: check whether it already answers at its address before you start a server, and leave the server running when you finish. Start a server detached from your shell, in a foreground command such as `nohup pnpm dev > #{Path.join(scratch_path, "server.log")} 2>&1 &`, so the command returns while it keeps running."
  end

  defp pictures do
    String.trim("""
    - Every picture you save comes back attached to the tool's reply, so check it in that same turn, without reading the file. Write one line of what it shows first, then compare that line with its name or label: the screen, the state it is in and the width. Take one that does not match again, once: half loaded, a sign-in page, another screen or the wrong width.
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

  # A state is shot again only when a commit since its picture can have changed it, so a round that leaves the
  # screens alone reshoots nothing.
  defp screens(%Task{} = task) do
    "Keep the screen states current, so the human sees each one as the latest commit leaves it. A state is one screen as a person meets it, the primary one or an empty, error or edge state the acceptance criteria name, with a lowercase hyphenated `key` and a `label` saying what it shows, such as `file-list-after-send`, \"File list just after Send\". #{known_screens(task)} Take `save_screen` of each state you shoot once you have reached it: one state, whole, at the width a person would meet it, with realistic content. Each shot replaces the state's last picture. A change with nothing on screen has no states: take none and say so."
  end

  # The states an earlier round shot keep their keys, so each one's pictures line up across commits.
  defp known_screens(%Task{} = task) do
    case Pipeline.list_screens(task) do
      [] ->
        "No state has been shot yet: shoot every state the change affects. The keys are yours to choose; later rounds keep them."

      screens ->
        "These states were shot before, each on the commit named. Read what changed since with `git diff <commit> HEAD`, and shoot again, under the same `key`, only a state that change can alter: what it renders, the data it shows or the way to reach it. Leave a state nothing has touched as it is. Shoot any state the change now affects that has no key yet: " <>
          Enum.map_join(screens, "; ", &"`#{&1.key}` (#{&1.label}) on #{String.slice(&1.commit || "no commit", 0, 7)}") <>
          "."
    end
  end

  defp query(%Task{issue: %Issue{} = issue}), do: "#{issue.title}\n\n#{issue.description}"
end
