defmodule Rail.Learnings.Actions.FinalizeTaskProposalsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Workers.FinalizeTaskProposals
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users

  setup %{project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ftp-1-#{id}",
        login: "dana-#{id}",
        name: "Dana",
        email: "dana-#{id}@ftp.example"
      })

    %{scope: Rail.Scope.for_user(user), user_id: user.id, task: learnings_task(project, "FTP-#{id}", :finalize)}
  end

  test "the merge carries out each choice as the one who chose it, and leaves one nobody chose", %{
    project: project,
    scope: scope,
    user_id: user_id,
    task: task
  } do
    old = learning(project, %{rule: "Send each comment.", kind: :decision})
    gone = learning(project, %{rule: "Run assets.build before QA.", kind: :environment})
    {:ok, add} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row.", kind: "convention"})

    {:ok, rewrite} =
      Learnings.save_task_proposal(task, %{action: "rewrite", target: old.id, rule: "Send as one.", kind: "decision"})

    {:ok, retire} = Learnings.save_task_proposal(task, %{action: "retire", target: gone.id})
    {:ok, unchosen} = Learnings.save_task_proposal(task, %{action: "add", rule: "Nobody chose.", kind: "qa"})

    {:ok, _chosen} = Learnings.choose_task_proposal(scope, add, :approved)
    {:ok, _chosen} = Learnings.choose_task_proposal(scope, rewrite, :approved)
    {:ok, _chosen} = Learnings.choose_task_proposal(scope, retire, :rejected)

    # Unmerged, the job changes nothing.
    assert :ok = perform_job(FinalizeTaskProposals, %{task_id: task.id})
    assert %LearningProposal{status: :pending} = Repo.reload!(add)

    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [merged_at: DateTime.utc_now()])
    assert :ok = perform_job(FinalizeTaskProposals, %{task_id: task.id})

    assert %LearningProposal{status: :approved, decided_by_id: ^user_id} = Repo.reload!(add)
    assert %Learning{status: :active, approved_by_id: ^user_id, auto: false} = Repo.get!(Learning, add.learning_id)
    assert %LearningProposal{status: :approved} = Repo.reload!(rewrite)
    assert %Learning{status: :retired} = Repo.reload!(old)
    assert %LearningProposal{status: :rejected, decided_by_id: ^user_id} = Repo.reload!(retire)
    assert %Learning{status: :active} = Repo.reload!(gone)
    assert %LearningProposal{status: :pending, choice: nil} = Repo.reload!(unchosen)

    # A second run finds nothing left to decide.
    assert :ok = Learnings.finalize_task_proposals(task)
  end

  test "a choice an earlier approval already decided is passed over, and a system choice approves as auto", %{
    project: project,
    scope: scope,
    task: task
  } do
    old = learning(project, %{rule: "Send each comment.", kind: :decision})

    {:ok, rewrite} =
      Learnings.save_task_proposal(task, %{action: "rewrite", target: old.id, rule: "Send as one.", kind: "decision"})

    {:ok, retire} = Learnings.save_task_proposal(task, %{action: "retire", target: old.id})
    {:ok, also} = Learnings.save_task_proposal(task, %{action: "retire", target: old.id, title: "Again"})
    {:ok, _chosen} = Learnings.choose_task_proposal(Rail.Scope.for_system(), rewrite, :approved)
    {:ok, _chosen} = Learnings.choose_task_proposal(scope, retire, :approved)
    {:ok, _chosen} = Learnings.choose_task_proposal(scope, also, :rejected)

    assert :ok = Learnings.finalize_task_proposals(task)

    # Approving the rewrite retired the rule and rejected what else was pending on it.
    assert %LearningProposal{status: :approved, decided_by_id: nil} = Repo.reload!(rewrite)
    assert %Learning{status: :active, auto: true} = Repo.get!(Learning, rewrite.learning_id)
    assert %LearningProposal{status: :rejected} = Repo.reload!(retire)
    assert %LearningProposal{status: :rejected} = Repo.reload!(also)
  end

  test "an approved draft retired since it was chosen is rejected instead", %{scope: scope, task: task} do
    {:ok, add} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row.", kind: "convention"})
    {:ok, _chosen} = Learnings.choose_task_proposal(scope, add, :approved)
    {:ok, _retired} = Learnings.retire_learning(scope, Repo.get!(Learning, add.learning_id))
    Repo.update_all(from(p in LearningProposal, where: p.id == ^add.id), set: [status: :pending])

    assert :ok = Learnings.finalize_task_proposals(task)
    assert %LearningProposal{status: :rejected} = Repo.reload!(add)
    assert %Learning{status: :retired} = Repo.get!(Learning, add.learning_id)
  end
end
