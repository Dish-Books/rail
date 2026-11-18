defmodule Rail.Learnings.Actions.SaveTaskProposalTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Workers.EmbedLearning

  setup %{project: project} do
    %{task: learnings_task(project, "STP-1", :finalize)}
  end

  test "an add drafts a proposed rule, pends a proposal of the task's, queues its embedding and is heard", %{
    project: %{id: project_id},
    task: %{id: task_id} = task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %LearningProposal{action: :add, status: :pending, task_id: ^task_id, learning_id: draft_id}} =
             Learnings.save_task_proposal(task, %{
               action: "add",
               title: "Broadcast after commit",
               rule: "Broadcast after the write commits.",
               kind: "convention",
               roles: ["engineer"],
               path_glob: nil
             })

    assert %Learning{status: :proposed, project_id: ^project_id, roles: [:engineer]} = Repo.get!(Learning, draft_id)
    assert_enqueued(worker: EmbedLearning, args: %{learning_id: draft_id})
    assert_received {:learnings_changed, ^project_id}
  end

  test "a rewrite and a retire target an active rule, and never a provisional one or another project's", %{
    project: project,
    task: task
  } do
    %Learning{id: active_id} = learning(project, %{rule: "Send each comment", kind: :decision}, status: :active)
    %Learning{id: provisional_id} = learning(project, %{rule: "Retry twice", kind: :qa}, status: :provisional)
    %{project: elsewhere} = triage_project()
    %Learning{id: other_id} = learning(elsewhere, %{rule: "Theirs", kind: :qa}, status: :active)

    assert {:ok, %LearningProposal{action: :rewrite, target_ids: [^active_id]}} =
             Learnings.save_task_proposal(task, %{
               action: "rewrite",
               target: active_id,
               rule: "Send the round's comments as one message.",
               kind: "decision"
             })

    assert {:ok, %LearningProposal{action: :retire, learning_id: ^active_id, summary: "Gone since RAIL-112"}} =
             Learnings.save_task_proposal(task, %{action: "retire", target: active_id, summary: "Gone since RAIL-112"})

    for target <- [provisional_id, other_id, nil], action <- ["rewrite", "retire"] do
      assert {:error, :not_found} =
               Learnings.save_task_proposal(task, %{action: action, target: target, rule: "New", kind: "qa"})
    end
  end

  test "a revise naming only the title keeps the action, the target and the draft's roles and path glob", %{
    project: project,
    task: task
  } do
    %Learning{id: active_id} = learning(project, %{rule: "Send each comment", kind: :decision}, status: :active)

    {:ok, %LearningProposal{id: id, learning_id: draft_id}} =
      Learnings.save_task_proposal(task, %{
        action: "rewrite",
        target: active_id,
        title: "One round",
        rule: "Send the round as one message.",
        kind: "decision",
        roles: ["engineer", "review"],
        path_glob: "lib/rail/pipeline/**"
      })

    assert {:ok, %LearningProposal{id: ^id, action: :rewrite, target_ids: [^active_id], title: "Narrower"}} =
             Learnings.save_task_proposal(task, %{proposal: id, title: "Narrower", roles: [], rule: nil})

    assert %Learning{roles: [:engineer, :review], path_glob: "lib/rail/pipeline/**"} = Repo.get!(Learning, draft_id)

    assert {:ok, %LearningProposal{}} = Learnings.save_task_proposal(task, %{proposal: id, path_glob: "lib/rail/**"})
    assert %Learning{rule: "Send the round as one message.", path_glob: "lib/rail/**"} = Repo.get!(Learning, draft_id)
  end

  test "a retire's revise changes only its title and summary", %{project: project, task: task} do
    %Learning{id: active_id} = learning(project, %{rule: "Run assets.build", kind: :environment}, status: :active)
    {:ok, %LearningProposal{id: id}} = Learnings.save_task_proposal(task, %{action: "retire", target: active_id})

    assert {:ok, %LearningProposal{learning_id: ^active_id, summary: "Setup builds them now"}} =
             Learnings.save_task_proposal(task, %{proposal: id, summary: "Setup builds them now", rule: "Ignored"})

    assert %Learning{rule: "Run assets.build", status: :active} = Repo.get!(Learning, active_id)
  end

  test "a decided proposal, another task's and an unknown one cannot be revised", %{project: project, task: task} do
    {:ok, decided} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row", kind: "convention"})
    {:ok, _rejected} = Learnings.reject_learning_proposal(system_scope(), decided)
    other_task = learnings_task(project, "STP-2", :finalize)
    {:ok, theirs} = Learnings.save_task_proposal(other_task, %{action: "add", rule: "Theirs", kind: "qa"})

    assert {:error, :already_decided} = Learnings.save_task_proposal(task, %{proposal: decided.id, title: "Again"})
    assert {:error, :not_found} = Learnings.save_task_proposal(task, %{proposal: theirs.id, title: "Mine now"})
    assert {:error, :not_found} = Learnings.save_task_proposal(task, %{proposal: "lpr_gone", title: "Nothing"})
    assert {:ok, %LearningProposal{status: :rejected, title: nil}} = Learnings.get_learning_proposal(decided.id)
  end

  test "a bad draft comes back as its changeset and leaves nothing behind, and an unknown action is refused", %{
    project: project,
    task: task
  } do
    assert {:error, %Ecto.Changeset{}} = Learnings.save_task_proposal(task, %{action: "add", kind: "convention"})
    {:ok, %LearningProposal{id: id}} = Learnings.save_task_proposal(task, %{action: "add", rule: "Ok", kind: "qa"})

    assert {:error, %Ecto.Changeset{}} =
             Learnings.save_task_proposal(task, %{proposal: id, kind: "nonsense", title: "Kept back"})

    assert {:error, :bad_action} = Learnings.save_task_proposal(task, %{action: "merge", rule: "Two", kind: "qa"})
    assert [%LearningProposal{id: ^id, title: nil}] = Learnings.list_learning_proposals(task_id: task.id)
    assert {:ok, [%Learning{rule: "Ok"}]} = Learnings.list_learnings(project_id: project.id, status: :proposed)
  end
end
