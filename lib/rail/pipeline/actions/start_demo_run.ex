defmodule Rail.Pipeline.Actions.StartDemoRun do
  @moduledoc """
  Spawns the demo stage's run: the brief naming the change to show, the one file
  the write-up goes in, and the process that records it.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only the demo knows about.

  The brief is only what Rail needs the run to know: where its worktree is, that
  it is being recorded, which tools Rail serves it, the one file Rail reads
  afterwards, and this task's own ticket, plan and QA findings. How to make a
  walkthrough worth watching is the role's prompt, which the project owns and
  edits - Rail has no opinion about it and no reason to repeat it on every run.

  The findings QA raised go in with what the human decided about each, because a
  defect somebody chose to live with is still in the application the run is
  about to film.
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
  Spawns `run`'s role to record a walkthrough of its task.

  The run is the whole handle: it carries the task to show, the worktree to run
  it in, and the role that does it. Returns whatever `Tools.start_os_process/2`
  does.
  """
  def start_demo_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]])
    File.mkdir_p!(Path.join(task.scratch_path, "demo"))

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
    dir = Path.join(scratch_path, "demo")
    file = Path.join(dir, "#{issue.identifier}.json")

    String.trim("""
    Record a walkthrough of the change described below, by driving the running application. #{workspace(task)}

    You are showing it, not changing it: write no application code and no tests, fix nothing, and never run a git command that writes - no commit, no push, no branch, no checkout, no stash. Reading the tree with git is how you know what changed.

    Nothing under #{scratch_path} is part of the change. It is your workspace, and Rail keeps it out of the commit.

    The browser is Rail's rather than yours. `browser_goto`, `browser_do`, `browser_look` and `browser_problems` drive one headless Chrome that stays where you left it between calls; it opens on the first call and Rail closes it when the task moves on.

    Rehearse, then record. Nothing is recorded until you call `demo_start`, and everything after it is, so the working out is free and the take is not:

    1. Read the ticket, the plan and the diff, sign in, and drive the whole walkthrough once - finding out where every control is and what each screen does when you touch it. The whole of it: every save and every submit the take will do, not up to the save and then Cancel. What a form does when it is saved is the part most likely to surprise you, and a rehearsal that stopped short of it has not rehearsed the take.
    2. Put back anything you changed while rehearsing - delete what you created - so the take starts from the state the walkthrough describes.
    3. Call `demo_start` and do the run you now know, end to end.

    Once `demo_start` is called you only drive the browser and narrate. Reading code, searching the repository, or working out why something did not behave is the take failing: the camera is on a still page the whole time you do it. Stop, put the data back, work it out off camera, and call `demo_start` again - it discards the last take, so a walkthrough that went wrong costs a retake rather than a bad video.

    `demo_say` is the narration, and Rail stamps each caption against the recording's own clock: say what is about to happen and then do it, or the caption lands over whatever came next. Rail renders captions in a bar under the video and never on it, so nothing you say covers the application - and nothing you say can point at it either. Name the acceptance criterion in `criterion` on the beat that proves one; that is how Rail reads back what the walkthrough covered.

    #{avoid(task)}
    Writing #{file} is how you hand the recording over, and it is the last thing you do. Write it from your worktree with a heredoc, the body and its closing JSON line at column zero:

    mkdir -p #{dir}
    cat > #{file} <<'JSON'
    {
      "title": "what this change lets somebody do, in a few words",
      "summary": "two or three sentences: what the change is, and what the walkthrough shows about it",
      "not_shown": "anything on the ticket the recording does not cover, and why"
    }
    JSON

    - A heredoc into #{file}, never an inline string. Write the whole file every recording; it describes the video that exists now, not what changed since the last one.
    - `not_shown` is empty when the walkthrough covered everything.
    - Write the file only once the recording is finished. If you stop part way, for a question or anything else, leave the file unwritten and the task waits for you.
    - Ask everything at once. Research to the end before you stop, then put every question you could not close in that one message, each `[QUESTION: ...]` on a line of its own. Rail collects them and the human answers the lot in a single pass, so one question at a time costs them a round trip each. A question you can settle from the app, the ticket or the plan is not a question.

    #{plan(task)}
    The ticket the change was built from:

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

  # QA already drove this application and a human already ruled on what it found.
  # A defect somebody decided to live with is still there, and walking into it on
  # camera is the one thing this run cannot recover from - so it is handed the
  # list rather than left to discover it.
  defp avoid(%Task{} = task) do
    case Enum.filter(Pipeline.list_qa_findings(task), &(QaFinding.state(&1) == :dismissed)) do
      [] ->
        ""

      dismissed ->
        """
        QA found these and a human decided to leave them. They are still in the application:

        #{Enum.map_join(dismissed, "\n", &finding_line/1)}
        """
    end
  end

  defp finding_line(%QaFinding{} = finding) do
    screen = if finding.screen, do: " (#{finding.screen})", else: ""

    "- [#{finding.severity}] #{finding.title}#{screen}"
  end

  # A task that skipped architect has no plan, and the ticket is then the whole
  # of what the walkthrough is meant to show.
  defp plan(%Task{} = task) do
    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content}} ->
        "The approved implementation plan the change was built from. What it named is what now works.\n\n#{String.trim(content)}\n"

      {:error, :not_found} ->
        "There is no implementation plan for this ticket, so the ticket below is the whole of it.\n"
    end
  end
end
