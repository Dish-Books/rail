defmodule Rail.Pipeline.Actions.StartPlanRun do
  @moduledoc """
  Starts the Plan step: one run whose agent leads Product, Designer and Architect as subagents
  to a ticket, the design options and the plan, each saved with Rail's tools.

  How the step works is the same for every project, so it is here in the brief rather than in a
  prompt file. Given an issue this creates the task too, and queues the ticket's move to In Progress.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.LearningsBrief
  import Rail.Pipeline.Utils.PlanSubagents

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
    subagents = plan_subagents(task)

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
        work_dir: worktree_path,
        agents: subagents
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{issue: %Issue{} = issue} = task, %Run{} = run) do
    String.trim("""
    You lead Rail's Plan step for the issue below: one conversation that ends with the ticket, the design options when the change has a screen, and the implementation plan, each saved with Rail's tools and approved by the human with one click. Product, Designer and Architect are your subagents, and each saves its own output: hand each its work with the Task tool, naming it, and never save anything yourself. You change nothing in the worktree yourself.

    How the Plan step works:

    1. Product first. Hand it the issue, its comments and anything the human has said, and have it save the ticket with `save_ticket`.
    2. Once the ticket is saved, hand it to Designer and Architect at once rather than one after the other. Designer only when the change has a screen: have it save three options with `save_design_option`. When nothing anyone sees changes there are no options: skip Designer and say so in one line.
    3. Architect does not wait for the design: have it plan everything that does not hang on the screen from the ticket. Once the options are saved, have it either write the screen-specific details for the option you recommend, naming that option when it saves with `save_plan`, or leave them until the pick. Never have it plan for all three.
    4. End the turn by saying what is saved and, when there are options, which one you recommend and why, in a sentence or two. The human picks in Rail, not in the chat.

    When you hand a subagent its work, include every rule from the rules section of this brief that bears on its output, word for word. A subagent sees only what you write it.

    Keeping the three in step:

    - Whenever the human asks for a change, hand it to the subagent that owns that output, and then to each other subagent whose output it affects, so the ticket, the design and the plan agree before your turn ends.
    - A pick arrives as a message that says only "I picked <title> (<key>)." Have Architect fill in or revise the screen-specific parts of the plan for that option and save it naming its key, and have Product update the ticket if the pick changes it. If the plan is already written for the pick, say it stands.
    - Rail records the pick in #{Path.join([task.scratch_path, "design", "picked"])} and deletes the options not picked; nobody writes that file. Approval needs a ticket, a plan, and, when there are options, a pick with the plan saved for it.
    - Comments arrive as one message, before or after approval, grouped by what they are on. Those on the design name each element of the picked option by its CSS selector with what it says and the comment: hand them to Designer to revise the picked option under its key, then to Architect or Product if the plan or the ticket must change. Those "On the ticket:" go to Product and those "On the plan:" to Architect, each naming its line by its label and quoting it as it read when the comment was written.
    - A plan saved after approval replaces the one Engineer builds from next. When a turn after approval saved the ticket or the plan, Rail updates the issue and tells Engineer as the turn ends, so say what you changed and leave the rest to it.

    Questions:

    - One round per turn. Collect every question you and the subagents could not close and ask them all in your last message, each on a line of its own as `[QUESTION: ...] [OPTIONS: <recommended> | <other>]`, your recommended answer first and the options split by `|`. Leave out `[OPTIONS: ...]` where the answer is free text. Rail collects them and the human answers the lot in a single pass. A question you can settle from the docs, the code or a named assumption is not a question.
    #{learnings_brief(run, ["#{issue.title}\n\n#{issue.description}"])}
    #{saved(task)}

    The ticket as it stands, its title, priority and estimate above its description:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole discussion; do not look for more.

    #{format_comments(issue.comments)}
    """)
  end

  # A turn after a deploy or a retry picks up from whatever is on disk, not from the start.
  defp saved(%Task{} = task) do
    ticket = Pipeline.read_ticket(task)
    design = Pipeline.read_design(task, pages: false)
    plan = Pipeline.read_plan(task)

    lines =
      Enum.filter(
        [
          ticket && "- The ticket: #{ticket.title}",
          design && design.options != [] &&
            "- Design options: #{Enum.map_join(design.options, ", ", &"#{&1.title} (#{&1.key})")}",
          design && design.picked && "- The human picked #{design.picked}.",
          plan && "- The plan, written for #{if plan.design, do: plan.design.key, else: "no design option"}."
        ],
        &is_binary/1
      )

    if lines == [],
      do: "Nothing is saved yet.",
      else: "Already saved, so carry on from it rather than starting over:\n\n" <> Enum.join(lines, "\n")
  end
end
