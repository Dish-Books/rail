defmodule Rail.Pipeline.Actions.StartCustomStageRun do
  @moduledoc """
  Spawns a custom stage's run: its workflow file's prompt as the system prompt, as the issue copied it, and a brief
  saying it reads the worktree, commits nothing and hands over one markdown file.

  `enter_stage/3` has already claimed the stage, started the run on the stage's role and made the worktree.
  """

  import Rail.Pipeline.Utils.FormatComments
  import Rail.Pipeline.Utils.FormatStageOutputs
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.LearningsBrief

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Spawns `run`'s custom stage agent on its task. Returns whatever `Tools.start_os_process/2` does.
  """
  def start_custom_stage_run(%Run{task: %Task{} = task, role: %Role{custom_stage: name} = role} = run)
      when is_binary(name) do
    task = Repo.preload(task, [:project, issue: [comments: :replies]], force: true)
    %IssueStage{prompt: prompt} = Issue.custom_stage(task.issue, name)
    File.mkdir_p!(task.scratch_path)

    prompt_text =
      Pipeline.build_prompt(
        task: task,
        context_snippet: brief(task, name, run),
        pending_answer: run.pending_answer,
        conversation_id: run.conversation_id
      )

    args =
      Tools.build_args(
        prompt: prompt_text,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: prompt,
        conversation_id: run.conversation_id,
        work_dir: task.worktree_path
      )

    Tools.start_os_process(run, args)
  end

  defp brief(%Task{issue: %Issue{} = issue} = task, name, %Run{} = run) do
    String.trim("""
    You are the #{name} stage of this task's workflow, for the issue below. What the stage does is your system prompt. The worktree is #{task.worktree_path}, on the branch #{task.worktree_name}: read it, run what you need in it, and change nothing. You make no commits, no push and no pull request. Nothing under #{task.scratch_path} is part of the change; it is your workspace and survives between turns.

    Your output is one markdown file, saved with `save_stage_output`. A person reads it and approves it in Rail, and every stage after this one is given it. Each save replaces the last, so save the whole file every time, and save it before you end your turn. Write no other file as your output.

    - Comments on the file arrive as one message, "On the output:", each naming its line by its label and quoting it as it read when the comment was written. Answer each by changing the file, save it again, and end your turn.
    - Ask everything at once. Ask every question you could not close in one `ask_questions` call before you end your turn, each with its options, your recommended answer first. Leave the options out where the answer is free text. A question you can settle from the code, the issue or the plan is not a question.
    - End the turn with what you saved in two or three sentences.
    #{plan(task)}#{format_stage_outputs(task, "What the stages before this one saved, each under its stage's name:", name)}#{learnings_brief(run, fn -> ["#{issue.title}\n\n#{issue.description}"] end)}
    The issue, its title, priority and estimate above its description:

    #{format_ticket(issue)}
    Every comment on the issue, oldest first. This is the whole of its discussion.

    #{format_comments(issue.comments)}
    """)
  end

  # An approved Plan published its ticket over the issue, so only its plan is said here.
  defp plan(%Task{} = task) do
    case Pipeline.read_plan(task) do
      %Round{plan: content, approved_at: %DateTime{}} when is_binary(content) ->
        "\nThe approved implementation plan:\n\n#{String.trim(content)}\n"

      _none ->
        ""
    end
  end
end
