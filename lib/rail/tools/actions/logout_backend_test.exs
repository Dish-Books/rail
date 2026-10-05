defmodule Rail.Tools.Actions.LogoutBackendTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "signs out the account in the backend's own config directory" do
    scope = system_scope()
    backend = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude"}))

    backend =
      Repo.update!(
        Backend.usage_changeset(backend, %{
          status: :ready,
          account_label: "me@example.com",
          account_detail: "max",
          fetched_at: DateTime.utc_now(),
          usage: [%{name: "Session", details: %{}}]
        })
      )

    config_dir = Backend.config_dir(backend)
    test_pid = self()

    stub(Tools, :run, fn "/usr/bin/claude", ["auth", "logout"], opts ->
      send(test_pid, {:env, opts[:env]})
      {"Successfully logged out\n", 0}
    end)

    assert {:ok, %Backend{status: :signed_out, account_label: nil, account_detail: nil, usage: [], fetched_at: nil}} =
             Tools.logout_backend(scope, backend)

    assert_received {:env, %{"CLAUDE_CONFIG_DIR" => ^config_dir}}
    assert %Backend{status: :signed_out, account_label: nil} = Repo.get!(Backend, backend.id)

    stub(Tools, :run, fn _exe, _args, _opts -> {"Not logged in\n", 1} end)
    assert {:error, "Not logged in"} = Tools.logout_backend(scope, backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {:error, :timeout} end)
    assert {:error, :timeout} = Tools.logout_backend(scope, backend)
  end
end
