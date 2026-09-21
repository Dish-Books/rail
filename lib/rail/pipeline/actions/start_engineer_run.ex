defmodule Rail.Pipeline.Actions.StartEngineerRun do
  @moduledoc """
  Spawns the engineer stage's run: the brief naming the plan to build and the
  file that says the build is finished, and the process that does it.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only engineer knows about.
  """

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Spawns `run`'s role to build its task.

  The run is the whole handle: it carries the task to build, the worktree to
  build it in, and the role that does it. Returns whatever
  `Tools.start_os_process/2` does.
  """
  def start_engineer_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]])
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))

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
    dir = Path.join(scratch_path, "commits")
    file = Path.join(dir, "#{issue.identifier}.md")

    String.trim("""
    Build the approved plan below. #{workspace(task)}

    Never run git. No commits, no branches, no pushes, no pull request, and never switch or rename the branch you are on. Rail commits your worktree for you once you are finished, authored by the person the ticket is assigned to and signed with their key, which is exactly why it is not yours to do.

    Nothing under #{scratch_path} is part of the change. It is your workspace, and Rail keeps it out of the commit.

    Writing #{file} is how you say the work is finished, and it is the last thing you do. Write it from your worktree with a heredoc, the body and its closing MSG line at column zero:

    mkdir -p #{dir}
    cat > #{file} <<'MSG'
    <one line saying what this change does>

    <what changed and why, as a commit body>
    MSG

    - A heredoc into #{file}, never an inline string.
    - Write it only when the work is actually finished and the project's own checks pass. If you stop part way, for a question or anything else, leave the file unwritten and the task waits for you rather than committing half a change.
    - Run every command in the foreground and wait for it, however long it takes, the project's own test and coverage runs included. Never start one in the background meaning to read it when it finishes: your turn ends the moment you stop writing, the CLI carrying you exits, and it kills whatever you left running. Nothing wakes you when it is done, so "I have started X and will check it shortly" is the end of the round with X unread and the work unfinished.
    - Review and QA findings come back as further turns of this same conversation. Each round writes the file again and becomes a commit of its own, so describe that round's change, not the whole ticket over again.
    - Ask everything at once. Research to the end before you stop, then put every question you could not close in that one message, each `[QUESTION: ...]` on a line of its own. Rail collects them and the human answers the lot in a single pass, so one question at a time costs them a round trip each. A question you can settle from the docs, the code or a named assumption is not a question.

    #{plan(task)}
    #{design(task)}
    The ticket it was planned from:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  defp workspace(%Task{worktree_path: worktree_path, worktree_name: branch, project: %Project{} = project}) do
    String.trim("""
    Your worktree is #{worktree_path} and every path you touch is under it. The branch #{branch} is already checked out and is named for this ticket; its base is #{project.default_branch} on remote `origin`. Other agents share this repository, so never work in the main checkout and never touch another worktree.
    """)
  end

  # The ticket carries the approved design as a screenshot, which says what the
  # screen looks like and nothing about how it is built. The page itself is what
  # the engineer transcribes, so it goes in whole rather than as a path it might
  # not open.
  defp design(%Task{} = task) do
    with %{picked: key, options: options} when is_binary(key) <- Pipeline.read_design(task),
         %{title: title, html: html, html_path: html_path} when is_binary(html) <-
           Enum.find(options, &(&1.key == key)) do
      """

      The human approved the design "#{title}", and this is the page it was approved as. It is also on disk at #{html_path}.

      <design title="#{title}">
      #{String.trim(html)}
      </design>

      Build that screen. Its markup carries the layout, states and copy the ticket only describes, so take them from it rather than inventing near-misses. Where the code cannot reasonably produce what the page shows, say so rather than quietly building something else.
      """
    else
      _no_approved_design -> ""
    end
  end

  # A task that skipped architect has no plan, and the ticket is then the whole
  # of the specification rather than a summary of one.
  defp plan(%Task{} = task) do
    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content}} ->
        "The approved implementation plan, which is the specification:\n\n#{String.trim(content)}"

      {:error, :not_found} ->
        "There is no implementation plan for this ticket, so the ticket below is the whole specification. Decide the approach yourself, following the patterns already in the code."
    end
  end
end
