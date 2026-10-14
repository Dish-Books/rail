defmodule Rail.Pipeline.Actions.StartEngineerRun do
  @moduledoc """
  Spawns the engineer stage's run: the brief naming the plan to build and how
  its commits are handed on, and the process that does it.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only engineer knows about.
  """

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatFindings
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.LearningsBrief
  import Rail.Pipeline.Utils.PrepareTurn
  import Rail.Pipeline.Utils.TicketTrailer

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  # A URI ends at the first quote, closing parenthesis, whitespace or tag, which is where every base64 one ends.
  @data_uri ~r/data:([^;,"')\s<]*)[^"')\s<]*/
  @inline_limit 1_024
  @page_limit 300_000
  @build_the_screen "Build that screen. Its markup carries the layout, states and copy the ticket only describes, so take them from it rather than inventing near-misses. Where the code cannot reasonably produce what the page shows, say so rather than quietly building something else."

  @doc """
  Spawns `run`'s role to build its task.

  The run is the whole handle: it carries the task to build, the worktree to
  build it in, and the role that does it. Returns whatever
  `Tools.start_os_process/2` does.
  """
  def start_engineer_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]])
    # The brief promises a workspace that survives between turns.
    File.mkdir_p!(task.scratch_path)
    behind = prepare_turn(%{run | task: task})

    prompt =
      behind <>
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
        work_dir: task.worktree_path
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{scratch_path: scratch_path, issue: %Issue{} = issue} = task, %Run{} = run) do
    String.trim("""
    Build the approved plan below. #{workspace(task)}

    Git is yours to use, commits included, except for what Rail does for you: no push and no pull request, and never switch or rename the branch you are on. For each turn Rail sets the worktree to commit as the person the ticket is assigned to, signed with their key, so commit as it is set and never change who commits. End every commit message with the line `#{ticket_trailer(issue)}`. Never rewrite commit history: no rebase, no amend, no reset or squash of a commit, nothing forced. Rail never force-pushes, so a branch whose history was rewritten is not pushed, and comes back to you to merge what was pushed back in.

    Never merge `origin/#{task.project.default_branch}` in unless the plan says to: a person brings the branch up to date with Update, which is a round of its own. A round that does merge it, which Rail fetched as the turn started, resolves every conflict the way both sides meant it and follows what the default branch changed through the code, tests and comments the branch relies on.

    Nothing under #{scratch_path} is part of the change. It is your workspace, and never committed. It survives between turns; `/tmp` and anything you left running do not.

    The machine is Rail's. Do not ask about it: work around what you can, and say in your last message what you could not. A headless Chrome you start yourself needs `--no-sandbox` here.

    A turn that ends with commits the remote does not have yet hands them over: Rail sends them on and the task moves to Review. So commit only finished work: commit when the work is done and the tests for what you changed pass, then end your turn. A commit message is one line saying what this change does, a blank line, then what changed and why. Work you leave uncommitted is not sent on; Rail warns that it is there and it waits for your next turn.

    Your last message is what the human reads, not the commit body: what you changed, how you checked it, and anything you could not do or disagreed with. A turn whose last words are "Running the tests now:" tells them nothing.

    - A test that fails only where your change does not touch is not a reason to hold the work back: name the test in the commit body and finish. If you stop part way, for a question or anything else, do not commit half a change, and the task waits for you.#{ci(task)}
    - Run every command in the foreground and wait for it, test runs included. Never start one in the background meaning to read it when it finishes: your turn ends the moment you stop writing, the CLI carrying you exits, and it kills whatever you left running. Nothing wakes you when it is done, so "I have started X and will check it shortly" is the end of the round with X unread and the work unfinished. A single command is cut off at ten minutes, so give a long one a `timeout` under that, or run it in parts, rather than backgrounding it.
    - Each round starts you on a clean conversation: this brief is all you are given of what came before. Commit the round as a commit of its own, describing this round's change, not the whole ticket over again.
    - Before you end a turn that commits, save your report with `save_report`: what you changed and why, and every file you changed that the plan did not name. For each finding below the plan covers, give the places you covered and those you left with why, and the test that failed first by its file and name. For each comment, say by its number what was done with it. QA, the code reviewer and the review agent read your report, and nothing else you say reaches them.
    - Ask everything at once. Research to the end before you stop, then ask every question you could not close in one `ask_questions` call before you end your turn, each with its options, your recommended answer first. Leave the options out where the answer is free text. The human sees the round when your turn ends and answers the lot in a single pass, so one question at a time costs them a round trip each. A question you can settle from the docs, the code or a named assumption is not a question.

    #{plan(task)}
    #{fixes(task)}#{design(task)}#{learnings_brief(run, fn -> ["#{issue.title}\n\n#{issue.description}" | plan_text(task)] end)}
    The ticket it was planned from:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  # A later round fixes what the review found, so the findings and the human's comments come with its plan.
  defp fixes(%Task{} = task) do
    case Pipeline.read_plan(task) do
      %Round{number: number} = round when number > 1 ->
        format_findings(task) <> comments(round, Pipeline.read_fix_plan(task))

      _first_or_none ->
        ""
    end
  end

  # Only the fix plan this round was approved from answers comments: an Update's round has none of its own.
  defp comments(%Round{plan_saved_at: saved_at}, %FixPlan{saved_at: saved_at, comments: [_first | _rest] = comments}) do
    lines = Enum.map_join(comments, "\n", &"#{&1.number}. On #{&1.place}: #{&1.text}")
    "The human's comments this round, by the numbers the plan uses:\n\n#{lines}\n\n"
  end

  defp comments(%Round{}, _none_or_another), do: ""

  defp ci(%Task{project: %Project{ci_command: command}}) when command in [nil, ""],
    do: "\n- This project has no CI command for Rail to run, so run its own checks yourself before you finish."

  defp ci(%Task{project: %Project{ci_command: command}}) do
    "\n- Once your turn hands your commits over, Rail runs `#{command}` on them before anything else sees them. If that fails, its output comes back to you as the next turn of this conversation. So never run `#{command}` or the whole test suite yourself: it would only run twice. Run the tests for the files you changed."
  end

  defp workspace(%Task{worktree_path: worktree_path, worktree_name: branch, project: %Project{} = project}) do
    String.trim("""
    Your worktree is #{worktree_path} and every path you touch is under it. The branch #{branch} is already checked out and is named for this ticket; its base is #{project.default_branch} on remote `origin`. Other agents share this repository, so never work in the main checkout and never touch another worktree.
    """)
  end

  # The ticket carries the approved design as a screenshot, which says nothing about how the screen is
  # built, so the page goes in too. Its large inline images would only push the brief past the model's limit.
  defp design(%Task{} = task) do
    with %{picked: key, options: options} when is_binary(key) <- Pipeline.read_design(task),
         %{title: title, html: html} = option when is_binary(html) <- Enum.find(options, &(&1.key == key)) do
      page = @data_uri |> Regex.replace(html, &leave_out_data_uri/2) |> String.trim()

      if String.length(page) <= @page_limit do
        """

        The human approved the design "#{title}", and this is the page it was approved as. It is also on disk at #{option.html_path}, with its screenshot at #{option.screenshot_path}. Rail left each inline image over 1 KB out of the page below, naming its media type and size where it was; the file on disk still has them.

        <design title="#{title}">
        #{page}
        </design>

        #{@build_the_screen}
        """
      else
        """

        The human approved the design "#{title}". Its page is at #{option.html_path} and its screenshot at #{option.screenshot_path}. The page was too large to include in this brief, even with its inline images left out, so read it from disk, and strip its `data:` URIs with `sed` before you read it whole.

        #{@build_the_screen}
        """
      end
    else
      _no_approved_design -> ""
    end
  end

  defp leave_out_data_uri(uri, media_type) when byte_size(uri) > @inline_limit do
    size =
      if byte_size(uri) >= 1_000_000,
        do: "#{Float.round(byte_size(uri) / 1_000_000, 1)} MB",
        else: "#{round(byte_size(uri) / 1_000)} KB"

    "[#{if media_type == "", do: "text/plain", else: media_type}, #{size}, left out of this brief]"
  end

  defp leave_out_data_uri(uri, _media_type), do: uri

  defp plan_text(%Task{} = task) do
    case Pipeline.read_plan(task) do
      %Round{plan: content, approved_at: %DateTime{}} when is_binary(content) -> [content]
      _unapproved -> []
    end
  end

  # A task that skipped architect has no plan, and the ticket is then the whole
  # of the specification rather than a summary of one.
  defp plan(%Task{} = task) do
    case Pipeline.read_plan(task) do
      %Round{plan: content, approved_at: %DateTime{}} when is_binary(content) ->
        "The approved implementation plan, which is the specification:\n\n#{String.trim(content)}"

      _unapproved ->
        "There is no implementation plan for this ticket, so the ticket below is the whole specification. Decide the approach yourself, following the patterns already in the code."
    end
  end
end
