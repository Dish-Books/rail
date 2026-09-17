defmodule Rail.Pipeline.Actions.StartReviewRun do
  @moduledoc """
  Spawns the review stage's run: the brief naming the change to read and the one
  file the findings go in, and the process that writes it.

  `enter_stage/3` has already claimed the stage, started the run and made the
  worktree; this is the part only review knows about.

  A task reaches review more than once, so the brief is not the same every time:
  the findings already on the task go into it with what the human decided about
  each, and the pass is then a verification of those as well as a reading of
  whatever the engineer has since changed.
  """

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Spawns `run`'s role to review its task.

  The run is the whole handle: it carries the task to review, the worktree to
  read it in, and the role that does it. Returns whatever
  `Tools.start_os_process/2` does.
  """
  def start_review_run(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]])
    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))

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

  defp brief(%Task{scratch_path: scratch_path, issue: %Issue{} = issue} = task) do
    dir = Path.join(scratch_path, "reviews")
    file = Path.join(dir, "#{issue.identifier}.json")

    String.trim("""
    Review the change described below. #{workspace(task)}

    You are reading it, not changing it: write no application code and no tests, and never run a git command that writes - no commit, no push, no branch, no checkout, no stash. Reading the tree with git is exactly what you are here for.

    Nothing under #{scratch_path} is part of the change, and the diff never includes it.

    Writing #{file} is how you report, and it is the last thing you do. Write it from your worktree with a heredoc, the body and its closing JSON line at column zero:

    mkdir -p #{dir}
    cat > #{file} <<'JSON'
    {
      "findings": [
        {
          "key": "short-stable-slug",
          "title": "one line naming the problem",
          "detail": "what is wrong and what it costs",
          "suggestion": "what would settle it",
          "file": "lib/path/to/file.ex",
          "line": 42,
          "severity": "major",
          "recommendation": "fix",
          "status": "open"
        }
      ]
    }
    JSON

    - A heredoc into #{file}, never an inline string. Write the whole file every pass; it is the complete report, not a list of what is new.
    - One finding per problem. Two symptoms of one cause are one finding; one file with three unrelated problems is three.
    - `key` is your own name for the problem, lowercase with hyphens, and it must stay the same for the same problem across passes. That is what lets a later pass update a finding rather than raise it twice.
    - `severity` is `blocker`, `major`, `minor` or `nit`, and says how much the problem matters. `recommendation` is `fix` or `skip`, and says whether you would act on it. They are separate axes: a nit worth the thirty seconds it costs is `fix`, and a blocker is never `skip`. Most changes have some of each.
    - `recommendation` is your advice, not your decision. A human reads it beside the finding and decides, so say which you would do rather than reporting everything as equal.
    - `detail` and `suggestion` have different readers, so do not write one twice. `detail` is what is wrong and what it costs, which is what the human rules on. `suggestion` is what would settle it, named concretely enough to act on, and it is the whole of what the engineer is handed. Say in `detail` whether this change caused the problem or merely stands next to it - something already broken before this change is `skip` unless the change made it worse.
    - `status` is `open` for a problem that still stands. Leave findings out entirely rather than inventing them: `{"findings": []}` is a clean review and is the right answer when the change is good.
    - A finding with no file is fine. Give `file` and `line` whenever you can point at one.
    - Report only what you checked. You have the worktree: open the callers, read the test, run it. A finding you could have confirmed and did not is a guess, and a guess costs the engineer a whole round.
    - Read the whole change before you write anything, and write the file only once you have finished. A finding against one file that the next file already answers is noise. If you stop part way, for a question or anything else, leave the file unwritten and the task waits for you.
    - Ask everything at once. Research to the end before you stop, then put every question you could not close in that one message, each `[QUESTION: ...]` on a line of its own. Rail collects them and the human answers the lot in a single pass, so one question at a time costs them a round trip each. A question you can settle from the docs, the code or the plan is not a question.

    #{outstanding(task)}
    #{plan(task)}
    The ticket the change was built from:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  defp workspace(%Task{worktree_path: worktree_path, worktree_name: branch, project: %Project{} = project}) do
    String.trim("""
    Your worktree is #{worktree_path} and every path you read is under it. The change is the branch #{branch} against #{project.default_branch} on remote `origin`: read it with `git diff origin/#{project.default_branch}...HEAD` from your worktree. Other agents share this repository, so never work in the main checkout and never touch another worktree.
    """)
  end

  # A task comes back to review once the engineer has been round again. What the
  # reviewer is owed is a verdict on each thing it already raised, so the rows
  # are handed back to it rather than left for it to remember.
  defp outstanding(%Task{} = task) do
    case Pipeline.list_review_findings(task) do
      [] ->
        ""

      findings ->
        """
        This change has been reviewed before and has been with the engineer since. These are the findings already on it, and this pass owes a verdict on every one of them.

        #{Enum.map_join(findings, "\n", &finding_line/1)}

        Restate each of those keys in the file you write, with `status` set to `fixed` where the change now addresses it and `not_fixed` where it does not, and say in `detail` what you actually checked. Keep a dismissed finding listed with the `status` it has and never argue it again - the human has ruled on it. Anything new you find in the change as it now stands is a new finding with a new key, and is welcome.
        """
    end
  end

  defp finding_line(%ReviewFinding{} = finding) do
    location = if finding.file, do: " (#{finding.file}#{finding.line && ":#{finding.line}"})", else: ""

    "- `#{finding.key}` [#{finding.severity}, human decided: #{decision_word(finding.decision)}, status: #{finding.status}] #{finding.title}#{location}"
  end

  defp decision_word(:fix), do: "fix it"
  defp decision_word(:skip), do: "dismissed, leave it"
  defp decision_word(nil), do: "not yet decided"

  # A task that skipped architect has no plan, and the ticket is then the whole
  # of the specification the change is read against.
  defp plan(%Task{} = task) do
    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content}} ->
        "The approved implementation plan the change was built from. It is the specification: where it named a file and what changed in it, that is what should have changed, and a change that did something else, or stopped short of what it called for, is a finding however good the code is.\n\n#{String.trim(content)}\n"

      {:error, :not_found} ->
        "There is no implementation plan for this ticket, so the ticket below is the whole specification.\n"
    end
  end
end
