defmodule Rail.Tools.Utils.TrustWorkspaceTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.TrustWorkspace

  alias Rail.Tools.Schemas.Backend

  setup do
    backend = %Backend{id: "bkd_trust_#{System.unique_integer([:positive])}", name: :claude}
    config_path = Path.join(Backend.config_dir(backend), ".claude.json")
    on_exit(fn -> File.rm_rf!(Backend.config_dir(backend)) end)

    %{backend: backend, config_path: config_path}
  end

  test "trusts each directory in a config that has none yet", %{backend: backend, config_path: config_path} do
    trust_workspace(backend, ["/repo", "/repo/.worktrees/task"])

    assert %{
             "projects" => %{
               "/repo" => %{"hasTrustDialogAccepted" => true},
               "/repo/.worktrees/task" => %{"hasTrustDialogAccepted" => true}
             }
           } = config_path |> File.read!() |> Jason.decode!()

    assert %File.Stat{mode: mode} = File.stat!(config_path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "keeps the account and whatever else the CLI recorded", %{backend: backend, config_path: config_path} do
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      Jason.encode!(%{
        "oauthAccount" => %{"emailAddress" => "agent@example.com"},
        "projects" => %{
          "/repo" => %{"allowedTools" => ["Bash"], "hasTrustDialogAccepted" => false},
          "/other" => %{"hasTrustDialogAccepted" => true}
        }
      })
    )

    trust_workspace(backend, ["/repo"])

    assert %{
             "oauthAccount" => %{"emailAddress" => "agent@example.com"},
             "projects" => %{
               "/repo" => %{"allowedTools" => ["Bash"], "hasTrustDialogAccepted" => true},
               "/other" => %{"hasTrustDialogAccepted" => true}
             }
           } = config_path |> File.read!() |> Jason.decode!()
  end

  test "leaves a config that already trusts every directory untouched", %{backend: backend, config_path: config_path} do
    File.mkdir_p!(Path.dirname(config_path))
    content = ~s({"projects": {"/repo": {"hasTrustDialogAccepted": true}}})
    File.write!(config_path, content)

    trust_workspace(backend, ["/repo"])

    assert File.read!(config_path) == content
  end

  test "writes nothing for a CLI without a trust dialog" do
    backend = %Backend{id: "bkd_codex_#{System.unique_integer([:positive])}", name: :codex}

    assert :ok = trust_workspace(backend, ["/repo"])
    refute File.exists?(Backend.config_dir(backend))
  end
end
