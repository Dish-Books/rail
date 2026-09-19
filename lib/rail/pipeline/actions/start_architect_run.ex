defmodule Rail.Pipeline.Actions.StartArchitectRun do
  @moduledoc """
  Spawns the architect stage's run: the brief naming the one file the plan goes
  in, and the process that writes it.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only architect knows about.
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
  Spawns `run`'s role to plan its task.

  The run is the whole handle: it carries the task to plan, the worktree to read
  it in, and the role that does it. Returns whatever `Tools.start_os_process/2`
  does.
  """
  def start_architect_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, issue: [comments: :replies])
    File.mkdir_p!(Path.join(task.scratch_path, "plans"))

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
    dir = Path.join(scratch_path, "plans")
    file = Path.join(dir, "#{issue.identifier}.md")

    String.trim("""
    Plan the implementation of the approved ticket below. You are planning it, not building it: change nothing in your worktree, write no application code and no tests, and create no branch.

    The plan is the file #{file}, and it is the whole of what you produce. The ticket itself is not yours to write.

    Write it from your worktree with a heredoc, the body and its closing PLAN line at column zero:

    mkdir -p #{dir}
    cat > #{file} <<'PLAN'
    ## Implementation plan

    <the implementation plan>
    PLAN

    - A heredoc into #{file}, never an inline string.
    - Keep the `## Implementation plan` heading on the first line.
    - Review comments come back as further turns of this same conversation. When that happens, write the file again.
    - Ask everything at once. Research to the end before you stop, then put every question you could not close in that one message, each `[QUESTION: ...]` on a line of its own. Rail collects them and the human answers the lot in a single pass, so one question at a time costs them a round trip each. A question you can settle from the docs, the code or a named assumption is not a question.

    The approved ticket:

    <ticket title="#{issue.title}">
    #{String.trim(issue.description || "")}
    </ticket>
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    #{design(task)}
    """)
  end

  # The ticket carries the approved design as a screenshot, which says what the
  # screen looks like and nothing about how it is built. The page itself is still
  # on disk, so the architect is pointed at that instead.
  defp design(%Task{} = task) do
    with %{picked: key, options: options} when is_binary(key) <- Pipeline.read_design(task),
         %{title: title, html_path: html_path, screenshot_path: screenshot_path} <-
           Enum.find(options, &(&1.key == key)) do
      """

      The human approved the design "#{title}". The page is #{html_path} and its screenshot is #{screenshot_path}. Read the page: the plan builds that screen, and its markup carries the layout, states and copy the ticket only describes. Where the code cannot reasonably produce what the page shows, say so in the plan rather than quietly building something else.
      """
    else
      _no_approved_design -> ""
    end
  end
end
