defmodule Rail.Pipeline.Actions.StartCuratorRun do
  @moduledoc """
  Spawns the project's curator on a task marked ready: it reads what the task taught and proposes rule changes a
  person approves or rejects beside its conversation, before a tech lead can approve or merge.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc "Spawns `run`'s curator on its task. Returns whatever `Tools.start_os_process/2` does."
  def start_curator_run(%Run{task: %Task{} = task, role: %Role{stage: :curator} = role} = run) do
    task = Repo.preload(task, [:project, :issue], force: true)
    dir = Path.join(task.scratch_path, "learnings")

    prompt =
      Pipeline.build_prompt(
        task: task,
        context_snippet: if(Run.resumable?(run), do: again(task, dir), else: brief(task, dir)),
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

  defp brief(%Task{issue: issue} = task, dir) do
    String.trim("""
    #{issue.identifier}, "#{issue.title}", was marked ready for review. Read what happened on it and propose how the project's rules should change because of it. A person reads each proposal beside this conversation and approves or rejects it, and can ask you here to change one or add another. A tech lead cannot approve or merge the task until every proposal is decided. You only propose: nothing changes the rules until a proposal is approved.

    Everything is in #{dir}:

    - ticket.md and plan.md, what was asked for and how it was planned.
    - findings.md, every review and QA finding with who decided it and how.
    - questions.md, every question an agent asked and who answered it.
    - transcripts/, each run's transcript, named by stage.
    - compare.diff, when it is there: what people changed after Review last read the code.
    - rules.md, the project's rules, each under its id.
    - observations.md, the corrections already recorded for this task.
    - proposals.md, what you or an earlier curator proposed on this task and how each was decided. Do not propose a rejected one again.

    The worktree is #{task.worktree_path}. Read it to check whether the code a rule names still exists. Change nothing in it or in #{dir}.

    Save each proposal with `save_learning_proposal`:

    - `add` drafts a new rule.
    - `rewrite` refines the active rule named in `target` with new wording, which replaces it once approved.
    - `retire` removes the active rule named in `target`, when its code is gone or this task contradicts it.

    To change a proposal you saved, save it again with its `proposal` id, giving only what changes. A proposal a person already decided can no longer change. Save nothing for a task that taught nothing new, and say so.

    End each turn with what you saved, in two or three sentences.
    """)
  end

  defp again(%Task{issue: issue}, dir) do
    String.trim("""
    #{issue.identifier} went back for more work and was marked ready for review again. The files in #{dir} are written afresh, and proposals.md says how each of your proposals was decided. Read what changed since your last pass, and propose only what it adds. Save, revise and end your turn as before.
    """)
  end
end
