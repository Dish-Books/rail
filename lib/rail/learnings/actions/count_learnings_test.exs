defmodule Rail.Learnings.Actions.CountLearningsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Support
  alias Rail.Support.Schemas.ChatMessage

  test "counts pending proposals and each rule status, for one project or all", %{project: project} do
    learning(project, %{rule: "Active", kind: :convention})
    learning(project, %{rule: "Provisional", kind: :convention}, status: :provisional)
    learning(project, %{rule: "Retired", kind: :convention}, status: :retired)
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})

    assert %{review: 1, active: 1, provisional: 1, retired: 1} = Learnings.count_learnings(project_id: project.id)
    assert %{review: review, active: active} = Learnings.count_learnings()
    assert review >= 1 and active >= 1
    assert %{review: 0, active: 0} = Learnings.count_learnings(project_id: "prj_none")
  end

  test "a pending support rule is not counted as waiting on review", %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/92"} = conn ->
        Req.Test.json(conn, %{
          "id" => "92",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s92", "author" => %{"type" => "user", "name" => "Maya"}, "body" => "<p>Export?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "92")
    line = Repo.insert!(%ChatMessage{conversation_id: conversation.id, author: :agent, text: "Proposed it."})
    rule = %{"key" => "print", "title" => "No printing", "rule" => "Never offer printing.", "kind" => "product"}
    {:ok, %{added: [_proposal]}} = Learnings.save_support_proposals(conversation, line, [rule])

    assert %{review: 0} = Learnings.count_learnings(project_id: project.id)
  end
end
