defmodule Rail.Pipeline.Actions.StartPlanRun do
  @moduledoc """
  Starts the Plan step: one run whose agent writes the ticket, the design options and the implementation
  plan itself, each saved with Rail's tools.

  How the step works is the same for every project, so it is here in the brief rather than in a
  prompt file. Given an issue this creates the task too, and queues the ticket's move to In Progress.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatStageOutputs
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.LearningsBrief

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
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

  # A task a custom stage started before Plan reaches it here, so its issue becomes the ticket now when Product is off.
  def start_plan_run(%Run{task: %Task{} = task, role: %Role{stage: :plan}} = run) do
    {:ok, _round} = issue_as_ticket(Repo.preload(task, [:project, :issue]))
    spawn_os_process(run, task.worktree_path)
  end

  # The spawn reads the run from another process, so it has to wait for the
  # commit; everything before it rolls back together.
  defp record_run(%Issue{} = issue, %Project{} = project, %Role{} = role) do
    Repo.transaction(fn ->
      with {:ok, task} <- Pipeline.create_task(issue, :plan),
           {:ok, _job} <- Issues.advance_issue_state(issue),
           task = Repo.preload(task, [:project, :issue]),
           {:ok, _round} <- issue_as_ticket(task),
           {:ok, worktree_path} <- ensure_worktree(project, task),
           {:ok, run} <- Pipeline.start_or_resume_run(task, role, worktree_path) do
        {run, worktree_path}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # With Product off nobody writes a ticket, so round 1 starts out holding the issue as it.
  defp issue_as_ticket(%Task{issue: %Issue{} = issue} = task) do
    if Issue.skips_step?(issue, :product) and Pipeline.read_plan(task) == nil do
      {:ok, round} = Pipeline.create_round(task)
      round |> Round.issue_ticket_changeset(issue) |> Repo.update()
    else
      {:ok, nil}
    end
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
    # Agents share Rail's host, so they dial its port: the public URL sits behind Cloudflare Access.
    kit = "http://localhost:#{RailWeb.Endpoint.config(:http)[:port]}/design-kit"
    on? = &(not Issue.skips_step?(issue, &1))

    String.trim("""
    You run Rail's Plan step for the issue below: one conversation that ends with one plan the human approves with one click. The plan is #{listing([on?.(:product) && "the ticket", on?.(:design) && "the design options when the change has a screen#{if on?.(:architect), do: ","}", on?.(:architect) && "the implementation plan"])}. You write #{if issue.skipped_steps == [], do: "all three", else: "each part this task has"} yourself, and save them with Rail's tools. You change nothing in the worktree: no application code, no tests, no branch.
    #{skipped(issue)}
    How the Plan step works:

    #{on? |> steps() |> Enum.with_index(1) |> Enum.map_join("\n", fn {step, number} -> "#{number}. #{step}" end)}

    Saving:

    #{Enum.join(saving(on?), "\n")}
    #{if on?.(:design), do: design_brief(dir, kit, on?), else: ""}
    Keeping the #{if issue.skipped_steps == [], do: "three", else: "parts"} in step:

    #{keeping(dir, on?)}
    Questions:

    - One round per turn. Collect every question you could not close and ask them all in one `ask_questions` call before you end your turn, each with its options, your recommended answer first. Leave the options out where the answer is free text. The human sees the round when your turn ends and answers the lot in a single pass. A question you can settle from the docs, the code or a named assumption is not a question.
    #{learnings_brief(run, ["#{issue.title}\n\n#{issue.description}"])}
    #{saved(task, on?)}#{format_stage_outputs(task, "Stages of this task's workflow ran before Plan and saved the files below, each under its stage's name. Read them with the issue, and give the plan check each one that bears on the plan, word for word.")}
    The ticket as it stands, its title, priority and estimate above its description:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole of its discussion.

    #{format_comments(issue.comments)}
    """)
  end

  # The steps of a Plan turn, numbered once the ones the workflow turned off are left out.
  defp steps(on?) do
    [
      on?.(:product) &&
        "The ticket first. Save it with `save_plan`, giving its `title` and `description`, as soon as you have a draft, so the human can read it while you work.",
      on?.(:design) &&
        "Then the design, only when the change has a screen: three options, each saved with `save_design_option`. When nothing anyone sees changes there are no options: skip them and say so in one line.",
      (on?.(:architect) and on?.(:design)) &&
        "Then the implementation plan, saved with `save_plan` as `plan`. Write everything that does not hang on the screen first. Once the options are saved, either write the screen-specific details for the option you recommend, naming it as `design` when you save, or leave them until the pick. Never plan for all three.",
      (on?.(:architect) and not on?.(:design)) &&
        "Then the implementation plan, saved with `save_plan` as `plan`.",
      on?.(:architect) &&
        "Have the plan checked before you end any turn that saved it, so the human reads a plan with nothing missing. Start one subagent on a clean context to read it against the code. It sees only what you write it, so give it the worktree path, the ticket and the implementation plan word for word as saved#{if on?.(:design), do: ", and the path of the page of the option the plan is written for"}. Ask it to report, each point with the file and line it rests on, what is missing: an acceptance criterion no step delivers, a caller, sibling or test of a changed function the plan leaves out, a migration, schema field, permission check or screen state the change needs and no step names. And what is likely wrong: a step that contradicts the code as it is, a file or function that does not exist, an approach that breaks the project's written standards or a rule you handed it, a test that would pass without the change. It changes nothing and saves nothing. Fix every point that holds, #{if on?.(:product), do: "carrying it to the ticket where it reaches, "}save again, and drop each that does not. One check a turn: what it revised is checked when the next turn saves the plan.",
      "End the turn by saying what is saved#{if on?.(:architect), do: "#{if on?.(:design), do: ",", else: " and"} what the check changed"} in a line each#{if on?.(:design), do: ", and, when there are options, which one you recommend and why, in a sentence or two. The human picks in Rail, not in the chat"}."
    ]
    |> Enum.filter(&is_binary/1)
    # The first step listed reads as the start, not as following another.
    |> List.update_at(0, &String.replace_prefix(&1, "Then t", "T"))
  end

  defp keeping(dir, on?) do
    in_step =
      Enum.filter(
        [on?.(:product) && "the ticket", on?.(:design) && "the design", on?.(:architect) && "the implementation plan"],
        &is_binary/1
      )

    headings = Enum.filter([on?.(:product) && ~s("On the ticket:"), on?.(:architect) && ~s("On the plan:")], &is_binary/1)

    """
    - Whenever the human asks for a change, carry it everywhere it reaches before your turn ends#{if match?([_, _ | _], in_step), do: ", so #{listing(in_step)} agree"}: "do not store it" removes the column, the migration, the schema field and their tests, not only the sentence.
    #{if on?.(:design), do: pick_brief(dir, on?), else: ""}- Comments arrive as one message before approval, grouped by what they are on.#{if on?.(:design), do: " Those on the design name each element of the picked option by its CSS selector with what it says and the comment: find the element, change the page, retake the screenshot and save under the same key, keeping the ids and structure of elements nobody commented on."}#{if headings != [], do: " Those #{listing(headings)} each name a line by its label and quote it as it read when the comment was written: answer by changing that line, and leave every line nobody commented on reading exactly as it did, so the other comments stay under their lines."}#{if on?.(:architect), do: " A fix the plan check brings is the one change a line nobody commented on can take."}
    """
  end

  defp saving(on?) do
    Enum.filter(
      [
        (on?.(:product) or on?.(:architect)) &&
          "- `save_plan` is the only way to hand over #{listing([on?.(:product) && "the ticket", on?.(:architect) && "the implementation plan"])}. Write #{listing([on?.(:product) && "no ticket file", on?.(:architect) && "no plan file"])}. A part you leave out of a save stays as the last save left it, and a part you give replaces it in full, so give #{listing([on?.(:product) && "the whole ticket body", on?.(:architect) && "the whole implementation plan"], "or")} every time you change it.",
        on?.(:product) &&
          "- `title` and `description` are the ticket, the description being its body in markdown, verbatim. `priority` and `estimate` keep whatever they are already set to when left out.",
        on?.(:architect) && "- `plan` opens with the `## Implementation plan` heading on its first line.",
        on?.(:architect) && on?.(:design) &&
          "- Name the option the implementation plan is written for as `design`, and leave `design` out while it is written for none. Approval needs a ticket, an implementation plan and, when there are options, a pick with the plan saved for it.",
        not (on?.(:architect) and on?.(:design)) && "- Approval needs #{approval_needs(on?)}."
      ],
      &is_binary/1
    )
  end

  # What stands in for each step this task's workflow turned off, so the agent reads the brief over its habit.
  defp skipped(%Issue{skipped_steps: []}), do: ""

  defp skipped(%Issue{} = issue) do
    builds_from = if Issue.skips_step?(issue, :product), do: "the issue", else: "the ticket"

    lines =
      Enum.flat_map(issue.skipped_steps, fn
        :product ->
          [
            "- Product is off: the issue below is the ticket, as it stands. Write no ticket and save none, since `save_plan` refuses a `title`, `description`, `priority` or `estimate`. Read the issue as the ticket for the rest of the plan."
          ]

        :design ->
          [
            "- Design is off: there are no design options, whatever the change shows on screen. Save none, since `save_design_option` refuses them."
          ]

        :architect ->
          [
            "- Architect is off: there is no implementation plan. Save none, since `save_plan` refuses a `plan`. Engineer builds from #{builds_from} alone."
          ]

        :demo ->
          ["- The demo is off: Review records none, so never pass `record_demo`."]
      end)

    "\nThis task's workflow turned these steps off, whatever the change is:\n\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp approval_needs(on?) do
    cond do
      on?.(:architect) ->
        "a ticket and an implementation plan"

      on?.(:design) ->
        "the ticket and, when there are options, a pick"

      true ->
        "the ticket"
    end
  end

  defp design_brief(dir, kit, on?) do
    """

    The design options:

    - Every file of them goes in #{dir}. Keep working files there too: it survives between turns, and `/tmp` does not.
    - #{dir}/<key>.html for each option: one self-contained page mocking up the screen at a 1920px-wide viewport with realistic content. The page can scroll: show each state the screen has at full size, one below the other, rather than fitting them into one view. Inline the page's own CSS. Load Tailwind as `<script src="#{kit}/tailwind.js"></script>` and Phosphor's icons as `<link rel="stylesheet" href="#{kit}/phosphor.css">`, both from Rail and never from a CDN, so the page is styled wherever Rail is reachable. Put no image in the page as a `data:` URI: the page goes into the engineer's brief, where a large one crowds out the work. Draw an image with CSS or inline SVG markup, or link it from a public URL, since Rail serves only the page and a file beside it does not load.
    - #{dir}/<key>.png for each option: a screenshot of its page, taken with headless Chrome:

    chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=8000 --window-size=1920,1170 --screenshot=#{dir}/<key>.png file://#{dir}/<key>.html

    Use `google-chrome`, or Google Chrome's full path on macOS, where that is what is installed. The window is taller than 1080 because headless Chrome keeps about 90px of it for itself.

    - Save each option with `save_design_option` as soon as its page and screenshot exist: its `key`, `title`, a `summary` of one or two sentences on the position it takes, `good_at` and `costs` as lists of short phrases, and `assumptions`, what you assumed so it can be vetoed. The human sees each option the moment it is saved, so save one before you start the next. A key is lowercase letters, digits and dashes, and names that option's files.
    - Retake an option's screenshot every time its page changes, and save the option again. The screenshot is what gets published. Write no manifest yourself.#{if on?.(:architect), do: "\n- When you plan for an option, read its page: its markup carries the layout, states and copy the ticket only describes. Plan every state it shows."}
    """
  end

  defp pick_brief(dir, on?) do
    """
    - A pick arrives as a message that says only "I picked <title> (<key>)." #{if on?.(:architect), do: "Fill in or revise the screen-specific parts of the implementation plan for that option and save it naming its key#{if on?.(:product), do: ", and update the ticket if the pick changes it"}. A pick should change the frontend parts of the plan and little else. If the plan is already written for the pick, say it stands.", else: if(on?.(:product), do: "Update the ticket if the pick changes it, and otherwise say it stands.", else: "Nothing needs saving for it.")}
    - Rail records the pick in #{Path.join(dir, "picked")} and deletes the options not picked; never write that file. After the pick only the picked option can be saved.
    """
  end

  # Joins the parts a sentence names, fewer when the workflow turned steps off.
  defp listing(parts, conjunction \\ "and") do
    {last, rest} = parts |> Enum.filter(&is_binary/1) |> List.pop_at(-1)
    if rest == [], do: last, else: "#{Enum.join(rest, ", ")} #{conjunction} #{last}"
  end

  # A turn after a deploy or a retry picks up from whatever is saved, not from the start.
  defp saved(%Task{} = task, on?) do
    design = Pipeline.read_design(task, pages: false)
    round = Pipeline.read_plan(task)

    lines =
      Enum.filter(
        [
          on?.(:product) && round && "- The ticket: #{round.ticket.title}",
          design && design.options != [] &&
            "- Design options: #{Enum.map_join(design.options, ", ", &"#{&1.title} (#{&1.key})")}",
          design && design.picked && "- The human picked #{design.picked}.",
          round && round.plan && on?.(:design) &&
            "- The plan, written for #{if round.design, do: round.design.key, else: "no design option"}.",
          round && round.plan && not on?.(:design) && "- The implementation plan."
        ],
        &is_binary/1
      )

    if lines == [],
      do: "Nothing is saved yet.",
      else: "Already saved, so carry on from it rather than starting over:\n\n" <> Enum.join(lines, "\n")
  end
end
