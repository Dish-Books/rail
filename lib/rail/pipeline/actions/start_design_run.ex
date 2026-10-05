defmodule Rail.Pipeline.Actions.StartDesignRun do
  @moduledoc """
  Spawns the design stage's run: the brief describing the three options the
  designer builds in scratch and saves one at a time, and the process that does.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only design knows about.
  """

  import Rail.Pipeline.Utils.FormatComments

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Spawns `run`'s role to design its task.

  The run is the whole handle: it carries the task to design, the worktree to do
  it in, and the role that does it. Returns whatever `Tools.start_os_process/2`
  does.
  """
  def start_design_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, issue: [comments: :replies])
    File.mkdir_p!(Path.join(task.scratch_path, "design"))

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

  defp brief(%Task{scratch_path: scratch_path, issue: %Issue{} = issue}) do
    dir = Path.join(scratch_path, "design")

    String.trim("""
    Design the user interface for the approved ticket below. You are designing it, not building it: change nothing in your worktree.

    Produce exactly three distinct design options, every file of them in #{dir}.

    1. #{dir}/<key>.html for each option: one self-contained page mocking up the screen at a 1920x1080 viewport with realistic content. Inline all CSS; scripts may come from a CDN.

    2. #{dir}/<key>.png for each option: a screenshot of its page, taken with headless Chrome:

    chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=8000 --window-size=1920,1170 --screenshot=#{dir}/<key>.png file://#{dir}/<key>.html

    Use `google-chrome`, or Google Chrome's full path on macOS, where that is what is installed. The window is taller than 1080 because headless Chrome keeps about 90px of it for itself.

    3. Save each option with the `save_design_option` tool as soon as its page and screenshot exist: its `key`, `title`, a `summary` of one or two sentences on the position it takes, `good_at` and `costs` as lists of short phrases, and `assumptions`, what you assumed so it can be vetoed. The human watching sees each option the moment it is saved, while you build the next, so save one before you start the next rather than all three at the end.

    - A key is lowercase letters, digits and dashes, and names that option's files.
    - Retake an option's screenshot every time its page changes, and save the option again. The screenshot is what gets published.
    - A save in the wrong shape, or one whose page or screenshot is not there yet, is refused naming each field, and the last good save stays. Fix it and save again. Write no manifest yourself.
    - Keep working files under #{dir} too. It survives between turns; `/tmp` does not.
    - The human picks one option and refines it with you in chat. Rail records the pick in #{dir}/picked and deletes the options not picked; never write that file.
    - If the ticket changes nothing anyone sees, say so in one line and save nothing. A human will skip the stage.
    - Ask everything at once. Research to the end before you stop, then put every question you could not close in that one message, each on a line of its own as `[QUESTION: ...] [OPTIONS: <recommended> | <other>]`, your recommended answer first and the options split by `|`. Leave out `[OPTIONS: ...]` where the answer is free text. Rail collects them and the human answers the lot in a single pass. A question you can settle from the ticket, the product or a named assumption is not a question, and neither is an edge case the ticket does not raise.

    The approved ticket:

    <ticket title="#{issue.title}">
    #{String.trim(issue.description || "")}
    </ticket>

    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end
end
