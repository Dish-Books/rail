defmodule Rail.Learnings.Actions.ChooseTaskProposalTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users

  setup %{project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ctp-1-#{id}",
        login: "dana-#{id}",
        name: "Dana",
        email: "dana-#{id}@ctp.example"
      })

    %{scope: Rail.Scope.for_user(user), user_id: user.id, task: learnings_task(project, "CTP-#{id}", :finalize)}
  end

  test "a choice keeps the proposal pending, changes no rule, can be changed and is heard", %{
    project: %{id: project_id},
    scope: scope,
    user_id: user_id,
    task: task
  } do
    {:ok, proposal} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row.", kind: "convention"})
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %LearningProposal{status: :pending, choice: :approved, decided_by_id: ^user_id}} =
             Learnings.choose_task_proposal(scope, proposal, :approved)

    assert_received {:learnings_changed, ^project_id}
    assert %Learning{status: :proposed} = Repo.get!(Learning, proposal.learning_id)

    assert {:ok, %LearningProposal{status: :pending, choice: :rejected}} =
             Learnings.choose_task_proposal(scope, proposal, :rejected)

    # A task's proposal is decided on the task, so the Learnings queue leaves it out.
    refute Enum.any?(Learnings.list_learning_proposals(project_id: project_id, task_id: :none), &(&1.id == proposal.id))
    assert %{review: 0} = Learnings.count_learnings(project_id: project_id)
  end

  test "a proposal already decided is refused", %{scope: scope, task: task} do
    {:ok, proposal} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row.", kind: "convention"})
    {:ok, _rejected} = Learnings.reject_learning_proposal(system_scope(), proposal)

    assert {:error, :already_decided} = Learnings.choose_task_proposal(scope, proposal, :approved)
    assert %LearningProposal{status: :rejected, choice: nil} = Repo.reload!(proposal)
  end

  test "once the task has merged, a choice decides at once", %{scope: scope, user_id: user_id, task: task} do
    {:ok, proposal} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row.", kind: "convention"})
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [merged_at: DateTime.utc_now()])

    assert {:ok, %LearningProposal{status: :approved, decided_by_id: ^user_id}} =
             Learnings.choose_task_proposal(scope, proposal, :approved)

    assert %Learning{status: :active, approved_by_id: ^user_id} = Repo.get!(Learning, proposal.learning_id)
  end
end
