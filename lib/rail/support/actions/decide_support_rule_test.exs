defmodule Rail.Support.Actions.DecideSupportRuleTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Users

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/" <> id} = conn ->
        Req.Test.json(conn, %{
          "id" => id,
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s#{id}", "author" => %{"type" => "user", "name" => "Maya"}, "body" => "<p>Export?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "88")
    {:ok, other} = Support.sync_intercom_conversation(workspace, "89")
    line = Repo.insert!(%ChatMessage{conversation_id: conversation.id, author: :agent, text: "Proposed it."})
    other_line = Repo.insert!(%ChatMessage{conversation_id: other.id, author: :agent, text: "Proposed one too."})
    rule = %{"key" => "print", "title" => "No printing", "rule" => "Never offer printing.", "kind" => "product"}
    {:ok, %{added: [proposal]}} = Learnings.save_support_proposals(conversation, line, [rule])
    {:ok, %{added: [other_proposal]}} = Learnings.save_support_proposals(other, other_line, [rule])
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "rule_#{unique}",
        login: "rule_#{unique}",
        name: "Dana Kim",
        email: "rule_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    Phoenix.PubSub.subscribe(Rail.PubSub, "support")

    %{
      conversation: conversation,
      proposal: proposal,
      other_proposal: other_proposal,
      user: user,
      scope: Scope.for_user(user)
    }
  end

  test "Approve makes the draft an active Triage rule approved by that person, and announces it", %{
    conversation: %{id: conversation_id} = conversation,
    proposal: %{id: proposal_id, learning_id: draft_id},
    user: %{id: user_id},
    scope: scope
  } do
    assert {:ok, %LearningProposal{id: ^proposal_id, status: :approved, decided_by_id: ^user_id}} =
             Support.decide_support_rule(scope, conversation, proposal_id, :approved)

    assert %Learning{status: :active, roles: [:triage], approved_by_id: ^user_id} = Repo.get!(Learning, draft_id)
    assert_receive {:support_changed, ^conversation_id}
  end

  test "a second decision, as from another tab, changes nothing", %{
    conversation: conversation,
    proposal: %{id: proposal_id, learning_id: draft_id},
    scope: scope
  } do
    {:ok, _approved} = Support.decide_support_rule(scope, conversation, proposal_id, :approved)

    assert {:error, :already_decided} = Support.decide_support_rule(scope, conversation, proposal_id, :approved)
    assert {:error, :already_decided} = Support.decide_support_rule(scope, conversation, proposal_id, :rejected)
    assert %LearningProposal{status: :approved} = Repo.get!(LearningProposal, proposal_id)
    assert %Learning{status: :active} = Repo.get!(Learning, draft_id)
  end

  test "Reject records who rejected it and changes no rule", %{
    conversation: conversation,
    proposal: %{id: proposal_id, learning_id: draft_id},
    user: %{id: user_id},
    scope: scope
  } do
    assert {:ok, %LearningProposal{status: :rejected, decided_by_id: ^user_id}} =
             Support.decide_support_rule(scope, conversation, proposal_id, :rejected)

    assert %Learning{status: :proposed} = Repo.get!(Learning, draft_id)
  end

  test "a rule from another conversation, or none at all, is not found", %{
    conversation: conversation,
    other_proposal: %{id: other_id},
    scope: scope
  } do
    assert {:error, :not_found} = Support.decide_support_rule(scope, conversation, other_id, :approved)
    assert {:error, :not_found} = Support.decide_support_rule(scope, conversation, "lpr_missing", :approved)
    assert %LearningProposal{status: :pending} = Repo.get!(LearningProposal, other_id)
  end

  test "a decision while the agent works is refused", %{
    conversation: conversation,
    proposal: %{id: proposal_id},
    scope: scope
  } do
    {:ok, drafting} = Support.draft_support_reply(system_scope(), conversation)

    assert {:error, :drafting} = Support.decide_support_rule(scope, drafting, proposal_id, :approved)
    assert %LearningProposal{status: :pending} = Repo.get!(LearningProposal, proposal_id)
  end

  test "a person without the conversation's project is refused", %{
    conversation: conversation,
    proposal: %{id: proposal_id},
    user: user
  } do
    {:ok, outsider} = Users.update_user(system_scope(), user, %{project_ids: []})

    assert {:error, :not_found} =
             Support.decide_support_rule(Scope.for_user(outsider), conversation, proposal_id, :approved)

    assert %LearningProposal{status: :pending} = Repo.get!(LearningProposal, proposal_id)
  end
end
