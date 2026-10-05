defmodule Rail.Tools.Actions.SetBackendTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "saves a Claude backend's token encrypted, and reads the backend as ready straight away" do
    scope = system_scope()
    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: System.find_executable("sh")})

    assert {:ok, %Backend{id: id, status: :ready, account_label: "Long-lived token", oauth_token: "sk-ant-oat01-abc"}} =
             Tools.set_backend_token(scope, backend, "  sk-ant-oat01-abc\n")

    assert %{rows: [[stored]]} = Repo.query!("SELECT oauth_token FROM backends WHERE id = $1", [id])
    refute stored =~ "sk-ant-oat01-abc"
  end

  test "a new token forgets that the last one was rejected, and no token signs the backend out" do
    scope = system_scope()
    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: System.find_executable("sh")})
    {:ok, backend} = Tools.set_backend_token(scope, backend, "old")

    rejected =
      Repo.update!(Backend.usage_changeset(backend, %{status: :signed_out, session_lost_at: DateTime.utc_now()}))

    assert {:ok, %Backend{status: :ready, session_lost_at: nil, oauth_token: "new"} = backend} =
             Tools.set_backend_token(scope, rejected, "new")

    for blank <- [nil, "  "] do
      assert {:ok, %Backend{status: :signed_out, oauth_token: nil, account_label: nil}} =
               Tools.set_backend_token(scope, backend, blank)
    end
  end

  test "refuses a token with a space in it" do
    scope = system_scope()
    {:ok, claude} = Tools.create_backend(scope, %{name: :claude, executable_path: "/bin/claude"})

    assert {:error, :invalid_token} = Tools.set_backend_token(scope, claude, "two words")
    assert %Backend{oauth_token: nil} = Repo.get!(Backend, claude.id)
  end
end
