defmodule Rail.Learnings.Actions.SaveSupportProposalsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Support
  alias Rail.Support.Schemas.ChatMessage

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/77"} = conn ->
        Req.Test.json(conn, %{
          "id" => "77",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s77", "author" => %{"type" => "user", "name" => "Maya"}, "body" => "<p>Export?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "77")
    first = Repo.insert!(%ChatMessage{conversation_id: conversation.id, author: :agent, text: "Proposed it."})
    second = Repo.insert!(%ChatMessage{conversation_id: conversation.id, author: :agent, text: "Reworded it."})

    rule = %{
      "key" => "print",
      "title" => "Never offer printing for export",
      "rule" => "Never suggest printing a recipe as a workaround for exporting it.",
      "why" => "The print layout leaves out ingredient costs.",
      "kind" => "product"
    }

    %{conversation: conversation, first: first, second: second, rule: rule}
  end

  test "a new key adds a pending Triage draft under the turn's chat line", %{
    project: %{id: project_id},
    conversation: %{id: conversation_id} = conversation,
    first: %{id: line_id} = first,
    rule: rule
  } do
    assert {:ok,
            %{
              added: [
                %LearningProposal{
                  project_id: ^project_id,
                  action: :add,
                  status: :pending,
                  title: "Never offer printing for export",
                  support_key: "print",
                  support_conversation_id: ^conversation_id,
                  support_chat_message_id: ^line_id,
                  learning: %Learning{
                    status: :proposed,
                    roles: [:triage],
                    kind: :product,
                    rule: "Never suggest printing a recipe as a workaround for exporting it.",
                    why: "The print layout leaves out ingredient costs."
                  }
                }
              ],
              edited: [],
              dropped: []
            }} = Learnings.save_support_proposals(conversation, first, [rule])
  end

  test "a second save with the same key redrafts that rule, and a third that changes nothing keeps it", %{
    conversation: conversation,
    first: %{id: line_id} = first,
    second: second,
    rule: rule
  } do
    {:ok, %{added: [%LearningProposal{id: proposal_id, learning_id: draft_id}]}} =
      Learnings.save_support_proposals(conversation, first, [rule])

    reworded = %{rule | "rule" => "Never offer printing in place of an export."}

    assert {:ok,
            %{
              added: [],
              edited: [
                %LearningProposal{
                  id: ^proposal_id,
                  support_chat_message_id: ^line_id,
                  learning: %Learning{id: ^draft_id, rule: "Never offer printing in place of an export."}
                }
              ],
              dropped: []
            }} = Learnings.save_support_proposals(conversation, second, [reworded])

    assert {:ok, %{added: [], edited: [], dropped: []}} =
             Learnings.save_support_proposals(conversation, second, [reworded])
  end

  test "a save that leaves an undecided key out deletes it and its draft", %{
    conversation: conversation,
    first: first,
    second: second,
    rule: rule
  } do
    {:ok, %{added: [%LearningProposal{id: proposal_id, learning_id: draft_id}]}} =
      Learnings.save_support_proposals(conversation, first, [rule])

    assert {:ok, %{added: [], edited: [], dropped: [%LearningProposal{id: ^proposal_id}]}} =
             Learnings.save_support_proposals(conversation, second, [])

    refute Repo.get(LearningProposal, proposal_id)
    refute Repo.get(Learning, draft_id)
  end

  test "a decided rule is untouched by a save that restates it or one that leaves it out", %{
    conversation: conversation,
    first: first,
    second: second,
    rule: rule
  } do
    {:ok, %{added: [proposal]}} = Learnings.save_support_proposals(conversation, first, [rule])
    {:ok, %LearningProposal{status: :approved}} = Learnings.approve_learning_proposal(system_scope(), proposal)
    restated = %{rule | "rule" => "Something else."}

    assert {:ok, %{added: [], edited: [], dropped: []}} =
             Learnings.save_support_proposals(conversation, second, [restated])

    assert {:ok, %{added: [], edited: [], dropped: []}} = Learnings.save_support_proposals(conversation, second, [])

    assert %LearningProposal{status: :approved, learning: %Learning{status: :active, rule: "Never suggest" <> _rest}} =
             LearningProposal |> Repo.get!(proposal.id) |> Repo.preload(:learning)
  end

  test "a key the agent repeats is saved once, and a rule with no key is skipped", %{
    conversation: conversation,
    first: first,
    rule: rule
  } do
    assert {:ok, %{added: [%LearningProposal{title: "Never offer printing for export"}]}} =
             Learnings.save_support_proposals(conversation, first, [rule, %{rule | "title" => "Again"}, %{"key" => 7}])
  end

  test "a rule Rail cannot save fails the whole save, naming its key", %{
    conversation: %{id: conversation_id} = conversation,
    first: first,
    rule: rule
  } do
    bad = %{rule | "key" => "bad", "kind" => "vibes"}

    assert {:error, {"bad", %Ecto.Changeset{} = changeset}} =
             Learnings.save_support_proposals(conversation, first, [rule, bad])

    assert %{kind: ["is invalid"]} = errors_on(changeset)
    refute Repo.exists?(from p in LearningProposal, where: p.support_conversation_id == ^conversation_id)
  end

  test "a redraft Rail cannot save fails the save and keeps the rule as it was", %{
    conversation: conversation,
    first: first,
    second: second,
    rule: rule
  } do
    {:ok, %{added: [%LearningProposal{id: proposal_id}]}} = Learnings.save_support_proposals(conversation, first, [rule])

    assert {:error, {"print", %Ecto.Changeset{}}} =
             Learnings.save_support_proposals(conversation, second, [%{rule | "rule" => nil}])

    assert %LearningProposal{learning: %Learning{rule: "Never suggest" <> _rest}} =
             LearningProposal |> Repo.get!(proposal_id) |> Repo.preload(:learning)
  end
end
