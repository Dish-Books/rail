defmodule Rail.Pipeline.Actions.StartDesignRun do
  @moduledoc """
  Spawns the design stage's run: the brief describing the three options the
  designer writes into scratch, and the process that writes them.

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
        work_dir: task.worktree_path,
        mcp: role.mcp_tools != []
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{scratch_path: scratch_path, issue: %Issue{} = issue}) do
    dir = Path.join(scratch_path, "design")

    String.trim("""
    Design the user interface for the approved ticket below. You are designing it, not building it: change nothing in your worktree.

    Produce exactly three distinct design options, every file of them in #{dir}.

    1. #{dir}/manifest.json, written with a heredoc, the closing MANIFEST line at column zero:

    cat > #{dir}/manifest.json <<'MANIFEST'
    {
      "options": [
        {
          "key": "<key>",
          "title": "<the option's name>",
          "summary": "<one or two sentences: the position this option takes>",
          "good_at": ["<a short phrase>", "..."],
          "costs": ["<a short phrase>", "..."],
          "assumptions": "<what you assumed, so it can be vetoed; empty when nothing>"
        }
      ]
    }
    MANIFEST

    2. #{dir}/<key>.html for each option: one self-contained page mocking up the screen at a 1920x1080 viewport with realistic content. Inline all CSS; scripts may come from a CDN.

    3. #{dir}/<key>.png for each option: a screenshot of its page, taken with headless Chrome:

    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --hide-scrollbars --window-size=1920,1080 --screenshot=#{dir}/<key>.png file://#{dir}/<key>.html

    Use `google-chrome` or `chromium` in place of that path where that is what is installed.

    - A key is lowercase letters, digits and dashes, and names that option's files.
    - Retake an option's screenshot every time its page changes. The screenshot is what gets published.
    - The human picks one option and refines it with you in chat. Rail records the pick in #{dir}/picked; never write that file.

    The approved ticket:

    <ticket title="#{issue.title}">
    #{String.trim(issue.description || "")}
    </ticket>

    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end
end
