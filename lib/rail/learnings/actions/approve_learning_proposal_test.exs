defmodule Rail.Learnings.Actions.ApproveLearningProposalTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Users

  setup %{project: project} do
    {:ok, user} = Users.register_oauth_user(%{github_id: "alp-1", login: "dana", name: "Dana", email: "dana@alp.example"})
    %{scope: Rail.Scope.for_user(user), user_id: user.id, project_id: project.id}
  end

  test "an add activates its draft with the person as approver", %{
    project: %{id: project_id} = project,
    scope: scope,
    user_id: user_id
  } do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %LearningProposal{status: :approved, decided_by_id: ^user_id}} =
             Learnings.approve_learning_proposal(scope, proposal)

    assert %Learning{status: :active, auto: false, approved_by_id: ^user_id} = Repo.reload!(draft)
    assert_received {:learnings_changed, ^project_id}
  end

  test "an add on a provisional rule confirms it", %{project: project, scope: scope} do
    rule = learning(project, %{rule: "Provisional", kind: :convention}, status: :provisional)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: rule.id})

    assert {:ok, _approved} = Learnings.approve_learning_proposal(scope, proposal)
    assert %Learning{status: :active} = Repo.reload!(rule)
  end

  test "a merge and a rewrite activate the draft and retire their targets", %{project: project, scope: scope} do
    for action <- [:merge, :rewrite] do
      targets = for n <- 1..2, do: learning(project, %{rule: "Old #{action} #{n}", kind: :convention})
      draft = learning(project, %{rule: "New #{action}", kind: :convention}, status: :proposed)

      proposal =
        Repo.insert!(%LearningProposal{
          project_id: project.id,
          action: action,
          learning_id: draft.id,
          target_ids: Enum.map(targets, & &1.id)
        })

      assert {:ok, _approved} = Learnings.approve_learning_proposal(scope, proposal)
      assert %Learning{status: :active} = Repo.reload!(draft)
      assert Enum.all?(targets, &match?(%Learning{status: :retired, retired_at: %DateTime{}}, Repo.reload!(&1)))
    end
  end

  test "a retire retires its rule and settles an override on it", %{project: project, scope: scope} do
    rule = learning(project, %{rule: "Code gone", kind: :environment})
    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :retire, learning_id: rule.id})

    assert {:ok, _approved} = Learnings.approve_learning_proposal(scope, proposal)
    assert %Learning{status: :retired} = Repo.reload!(rule)
    assert %LearningProposal{status: :approved} = Repo.reload!(override)
  end

  test "a conflict and an override are marked resolved and change no rule", %{project: project, scope: scope} do
    rule = learning(project, %{rule: "Order by severity", kind: :decision})

    for action <- [:conflict, :override] do
      proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: action, learning_id: rule.id})
      assert {:ok, %LearningProposal{status: :approved}} = Learnings.approve_learning_proposal(scope, proposal)
    end

    assert %Learning{status: :active} = Repo.reload!(rule)
  end

  test "a promote opens a Linear issue and keeps the rule active", %{project: project, scope: scope} do
    rule = learning(project, %{rule: "Context functions take Rail.Scope first", kind: :convention})

    proposal =
      Repo.insert!(%LearningProposal{
        project_id: project.id,
        action: :promote,
        learning_id: rule.id,
        promote_to: :credo_check,
        summary: "Broken 3 times"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Make a lint check of a rule that keeps being broken"
      assert body =~ "Context functions take Rail.Scope first"

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_promote_1", "identifier" => "TST-91", "title" => "Make a lint check"}
          }
        }
      })
    end)

    assert {:ok, %LearningProposal{issue_id: issue_id}} = Learnings.approve_learning_proposal(scope, proposal)
    assert %Issue{identifier: "TST-91"} = Repo.get!(Issue, issue_id)
    assert %Learning{status: :active} = Repo.reload!(rule)
  end

  test "a promote Linear refuses is not approved", %{project: project, scope: scope} do
    rule = learning(project, %{rule: "Broken rule", kind: :convention})
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :promote, learning_id: rule.id})

    Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"issueCreate" => %{"success" => false}}}))

    assert {:error, {:linear_mutation_failed, "issueCreate"}} = Learnings.approve_learning_proposal(scope, proposal)
    assert %LearningProposal{status: :pending} = Repo.reload!(proposal)
  end

  test "a second approval, from another click or tab, is told it was already decided", %{project: project, scope: scope} do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})

    assert {:ok, _approved} = Learnings.approve_learning_proposal(scope, proposal)
    assert {:error, :already_decided} = Learnings.approve_learning_proposal(scope, proposal)
  end

  test "pending proposals are listed oldest first, filtered by kind, and loaded whole", %{
    project: project,
    project_id: project_id
  } do
    old_rule = learning(project, %{rule: "Old", kind: :convention}, status: :provisional)
    %{id: target_id} = target = learning(project, %{rule: "Target", kind: :convention})
    draft = learning(project, %{rule: "Draft", kind: :decision}, status: :proposed)

    %{id: first_id} =
      Repo.insert!(%LearningProposal{project_id: project_id, action: :add, learning_id: old_rule.id})

    task = learnings_task(project, "PRP-1")

    {:ok, [_rule]} =
      Learnings.record_corrections(task, [
        %Rail.Pipeline.Schemas.DiffComment{id: "dcm_prp", path: "a.ex", line_text: "x", body: "Why"}
      ])

    [observation] = Repo.all(from o in Rail.Learnings.Schemas.Observation, where: o.task_id == ^task.id)

    %{id: second_id} =
      Repo.insert!(%LearningProposal{
        project_id: project_id,
        action: :merge,
        learning_id: draft.id,
        target_ids: [target.id],
        evidence_ids: [observation.id]
      })

    assert [%LearningProposal{id: ^first_id}, %LearningProposal{id: ^second_id, learning: %Learning{}}] =
             Learnings.list_learning_proposals(project_id: project_id)

    assert [%LearningProposal{id: ^second_id}] =
             Learnings.list_learning_proposals(project_id: project_id, kind: :decision)

    assert [%LearningProposal{id: ^first_id}, %LearningProposal{id: ^second_id}] =
             Learnings.list_learning_proposals(project_id: [project_id])

    assert [] = Learnings.list_learning_proposals(project_id: [])
    assert [_first, _second] = Enum.filter(Learnings.list_learning_proposals(), &(&1.project_id == project_id))

    assert {:ok,
            %LearningProposal{
              learning: %Learning{rule: "Draft"},
              targets: [%Learning{id: ^target_id}],
              evidence: [%{task: %{issue: %{identifier: "PRP-1"}}}]
            }} =
             Learnings.get_learning_proposal(second_id)

    assert {:error, :not_found} = Learnings.get_learning_proposal("lpr_none")
  end
end
