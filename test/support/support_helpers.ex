defmodule RailTest.SupportHelpers do
  @moduledoc """
  Arranges support tests: an Intercom workspace on a project and a conversation synced into it from Intercom.
  """

  alias Rail.Scope
  alias Rail.Support

  @doc """
  A conversation in a new Intercom workspace on `project`: Marta's "Two bugs." and then each of `parts`, as Intercom
  sends conversation parts. Returns it with everything its page shows.
  """
  def support_conversation(project, parts \\ []) do
    unique = System.unique_integer([:positive])
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app#{unique}"}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(Scope.for_system(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    Req.Test.expect(Rail.Intercom, fn conn ->
      Req.Test.json(conn, %{
        "id" => "#{unique}",
        "created_at" => 1_790_000_000,
        "updated_at" => 1_790_000_100,
        "state" => "open",
        "source" => %{"id" => "src1", "body" => "<p>Two bugs.</p>", "author" => %{"type" => "user", "name" => "Marta"}},
        "conversation_parts" => %{"conversation_parts" => parts}
      })
    end)

    {:ok, synced} = Support.sync_intercom_conversation(workspace, "#{unique}")
    {:ok, conversation} = Support.get_support_conversation(Scope.for_system(), synced.id)
    conversation
  end
end
