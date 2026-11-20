defmodule Rail.Support.Workers.RunSupportAgentTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Workers.RunSupportAgent
  alias Rail.Tools

  test "a conversation that is gone has nothing to run" do
    reject(Tools, :run_agent, 3)
    assert :ok = perform_job(RunSupportAgent, %{"conversation_id" => "scv_gone"})
  end

  test "runs the agent once on the conversation" do
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    %{project: project} = triage_project(tracker: :local)
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/66"} = conn ->
        Req.Test.json(conn, %{
          "id" => "66",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s66", "author" => %{"type" => "user", "name" => "Tom"}, "body" => "<p>Barcodes?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, %{id: conversation_id} = conversation} = Support.sync_intercom_conversation(workspace, "66")

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      conversation
      |> Conversation.scratch_path()
      |> Path.join("result.json")
      |> File.write!(Jason.encode!(%{"message" => "Steps given.", "reply" => "Hi Tom", "items" => []}))

      {:ok, ""}
    end)

    assert :ok = perform_job(RunSupportAgent, %{"conversation_id" => conversation_id})
    assert %Conversation{reply_text: "Hi Tom"} = Repo.get!(Conversation, conversation_id)
  end
end
