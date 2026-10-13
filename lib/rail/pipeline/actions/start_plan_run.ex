defmodule Rail.Pipeline.Actions.StartPlanRun do
  @moduledoc """
  Starts the Plan step: one run whose agent writes the ticket, the design options and the implementation
  plan itself, each saved with Rail's tools.

  How the step works is the same for every project, so it is here in the brief rather than in a
  prompt file. Given an issue this creates the task too, and queues the ticket's move to In Progress.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.LearningsBrief

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Creates the task for an issue at Plan and starts its run, or spawns a Plan run `enter_stage/3`
  already started.

  A checkout no worktree can be made in leaves the issue without a task, so it can be started
  again; a run that is recorded but fails to spawn keeps its task, with the failure on the run.
  Returns whatever `Tools.start_os_process/2` does.
  """
  def start_plan_run(%Issue{} = issue) do
    %Issue{project: %Project{} = project} = issue = Repo.preload(issue, :project)
    {:ok, %Role{} = role} = Roles.get_role(project_id: project.id, stage: :plan)

    with {:ok, {run, worktree_path}} <- record_run(issue, project, role) do
      # Pages showing whether an issue has a task, such as Triage, learn of it here.
      broadcast_pipeline_changed(run)
      spawn_os_process(%{run | role: role}, worktree_path)
    end
  end

  def start_plan_run(%Run{task: %Task{} = task, role: %Role{stage: :plan}} = run) do
    spawn_os_process(run, task.worktree_path)
  end

  # The spawn reads the run from another process, so it has to wait for the
  # commit; everything before it rolls back together.
  defp record_run(%Issue{} = issue, %Project{} = project, %Role{} = role) do
    Repo.transaction(fn ->
      with {:ok, task} <- Pipeline.create_task(issue, :plan),
           {:ok, _job} <- Issues.advance_issue_state(issue),
           task = Repo.preload(task, [:project, :issue]),
           {:ok, worktree_path} <- ensure_worktree(project, task),
           {:ok, run} <- Pipeline.start_or_resume_run(task, role, worktree_path) do
        {run, worktree_path}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp spawn_os_process(%Run{task: %Task{} = task, role: %Role{} = role} = run, worktree_path) do
    task = Repo.preload(task, [issue: [comments: :replies]], force: true)
    File.mkdir_p!(Path.join(task.scratch_path, "design"))

    prompt =
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
        work_dir: worktree_path
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{issue: %Issue{} = issue} = task, %Run{} = run) do
    dir = Path.join(task.scratch_path, "design")

    String.trim("""
    You run Rail's Plan step for the issue below: one conversation that ends with one plan the human approves with one click. The plan is the ticket, the design options when the change has a screen, and the implementation plan. You write all three yourself, and save them with Rail's tools. You change nothing in the worktree: no application code, no tests, no branch.

    How the Plan step works:

    1. The ticket first. Save it with `save_plan`, giving its `title` and `description`, as soon as you have a draft, so the human can read it while you work.
    2. Then the design, only when the change has a screen: three options, each saved with `save_design_option`. When nothing anyone sees changes there are no options: skip them and say so in one line.
    3. Then the implementation plan, saved with `save_plan` as `plan`. Write everything that does not hang on the screen first. Once the options are saved, either write the screen-specific details for the option you recommend, naming it as `design` when you save, or leave them until the pick. Never plan for all three.
    4. When the work is too big for one ticket, or the human asks for a split, decide where it splits from the code and save it with `save_split`. The ticket you saved stays the parent's, whole.
    5. End the turn by saying what is saved and, when there are options, which one you recommend and why, in a sentence or two. The human picks in Rail, not in the chat.

    Saving:

    - `save_plan` is the only way to hand over the ticket and the implementation plan. Write no ticket file and no plan file. A part you leave out of a save stays as the last save left it, and a part you give replaces it in full, so give the whole ticket body or the whole implementation plan every time you change it.
    - `title` and `description` are the ticket, the description being its body in markdown, verbatim. `priority` and `estimate` keep whatever they are already set to when left out.
    - `plan` opens with the `## Implementation plan` heading on its first line.
    - Name the option the implementation plan is written for as `design`, and leave `design` out while it is written for none. Approval needs a ticket, an implementation plan and, when there are options, a pick with the plan saved for it.

    The design options:

    - Every file of them goes in #{dir}. Keep working files there too: it survives between turns, and `/tmp` does not.
    - #{dir}/<key>.html for each option: one self-contained page mocking up the screen at a 1920x1080 viewport with realistic content. Inline all CSS; scripts may come from a CDN. Put no image in the page as a `data:` URI: the page goes into the engineer's brief, where a large one crowds out the work. Draw an image with CSS or inline SVG markup, or link it from a public URL, since Rail serves only the page and a file beside it does not load.
    - #{dir}/<key>.png for each option: a screenshot of its page, taken with headless Chrome:

    chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=8000 --window-size=1920,1170 --screenshot=#{dir}/<key>.png file://#{dir}/<key>.html

    Use `google-chrome`, or Google Chrome's full path on macOS, where that is what is installed. The window is taller than 1080 because headless Chrome keeps about 90px of it for itself.

    - Save each option with `save_design_option` as soon as its page and screenshot exist: its `key`, `title`, a `summary` of one or two sentences on the position it takes, `good_at` and `costs` as lists of short phrases, and `assumptions`, what you assumed so it can be vetoed. The human sees each option the moment it is saved, so save one before you start the next. A key is lowercase letters, digits and dashes, and names that option's files.
    - Retake an option's screenshot every time its page changes, and save the option again. The screenshot is what gets published. Write no manifest yourself.
    - When you plan for an option, read its page: its markup carries the layout, states and copy the ticket only describes. Plan every state it shows.

    Keeping the three in step:

    - Whenever the human asks for a change, carry it everywhere it reaches before your turn ends, so the ticket, the design and the implementation plan agree: "do not store it" removes the column, the migration, the schema field and their tests, not only the sentence.
    - A pick arrives as a message that says only "I picked <title> (<key>)." Fill in or revise the screen-specific parts of the implementation plan for that option and save it naming its key, and update the ticket if the pick changes it. A pick should change the frontend parts of the plan and little else. If the plan is already written for the pick, say it stands.
    - Rail records the pick in #{Path.join(dir, "picked")} and deletes the options not picked; never write that file. After the pick only the picked option can be saved.
    - Comments arrive as one message before approval, grouped by what they are on. Those on the design name each element of the picked option by its CSS selector with what it says and the comment: find the element, change the page, retake the screenshot and save under the same key, keeping the ids and structure of elements nobody commented on. Those "On the ticket:" and "On the plan:" each name a line by its label and quote it as it read when the comment was written: answer by changing that line, and leave every line nobody commented on reading exactly as it did, so the other comments stay under their lines.

    A split:

    - Two or more children in the order they run, each a ticket of its own with its own branch and pull request: its `title`, its `ticket`, its `estimate`, its part of the plan as `plan`, `builds_on`, the numbers of the earlier children it needs merged first, and `builds_screen`, true for each child that builds the approved design's screen, since only those children get the design. Your implementation plan still covers the whole change, so the human can read it in one place. With a split saved, approval makes each child a sub-issue with a task of its own.
    - Plan the split on purpose, before you write the parts, as vertical slices: each child ships a whole, working piece of the change through every layer it touches, and merges on its own with the default branch working and its tests passing.
    - Order and cut the children so none is reworked by a later one, and none carries a temporary stand-in to tide it over until a sibling lands: no stubs, shims, placeholder screens, flags or half-wired states. Where a cut would need one, cut elsewhere or keep that work in one child.
    - A child builds on another only where it truly needs that work merged first. It starts when that one merges, so every needless dependency is time the children spend waiting.
    - Each child's ticket has its own acceptance criteria, taken from the parent's. Its part is a complete plan in the same sections as yours, opening with the `## Implementation plan` heading, since the child's engineer reads nothing else of the plan.
    - Each `save_split` replaces the whole split, so every save carries every child complete. Save an empty list to remove the split.

    Questions:

    - One round per turn. Collect every question you could not close and ask them all in one `ask_questions` call before you end your turn, each with its options, your recommended answer first. Leave the options out where the answer is free text. The human sees the round when your turn ends and answers the lot in a single pass. A question you can settle from the docs, the code or a named assumption is not a question.
    #{learnings_brief(run, ["#{issue.title}\n\n#{issue.description}"])}
    #{saved(task)}

    The ticket as it stands, its title, priority and estimate above its description:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  # A turn after a deploy or a retry picks up from whatever is saved, not from the start.
  defp saved(%Task{} = task) do
    design = Pipeline.read_design(task, pages: false)
    round = Pipeline.read_plan(task)
    split = Pipeline.read_split(task)

    lines =
      Enum.filter(
        [
          round && "- The ticket: #{round.ticket.title}",
          design && design.options != [] &&
            "- Design options: #{Enum.map_join(design.options, ", ", &"#{&1.title} (#{&1.key})")}",
          design && design.picked && "- The human picked #{design.picked}.",
          round && round.plan &&
            "- The plan, written for #{if round.design, do: round.design.key, else: "no design option"}.",
          split &&
            "- A split into #{length(split.children)}: #{Enum.map_join(split.children, "; ", &"#{&1.number}. #{&1.title}")}."
        ],
        &is_binary/1
      )

    if lines == [],
      do: "Nothing is saved yet.",
      else: "Already saved, so carry on from it rather than starting over:\n\n" <> Enum.join(lines, "\n")
  end
end
