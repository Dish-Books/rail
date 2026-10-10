defmodule Rail.Tools.Actions.InstallToolchainTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools
  alias Rail.Tools.Schemas.ToolchainInstall
  alias Rail.Tools.Workers.InstallToolchain

  setup do
    stub(Git, :git_repo?, &call_original(Git, :git_repo?, [&1]))
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    remote = create_temp_git_repo(prefix: "rail_toolchain_remote")
    File.write!(Path.join(remote, ".tool-versions"), "erlang 28.5.0.7\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "pin erlang"])
    clone = create_temp_git_repo(prefix: "rail_toolchain_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])

    tmp_dir = Path.join(System.tmp_dir!(), "install_toolchain_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    id = System.unique_integer([:positive])

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Toolchain Project #{id}",
        github_repo: "org/toolchain-#{id}",
        github_installation_id: id,
        key: "TCI#{id}",
        default_branch: "main",
        clone_path: clone,
        toolchain_command: "cat .tool-versions > #{tmp_dir}/ran"
      })
      |> Repo.insert!()

    %{project: project, clone: clone, tmp_dir: tmp_dir}
  end

  test "the command runs once for a commit of the default branch, in a checkout of it", %{
    project: %Project{id: project_id} = project,
    clone: clone,
    tmp_dir: tmp_dir
  } do
    head_sha = clone |> git!(["rev-parse", "origin/main"]) |> String.trim()

    assert {:ok, %ToolchainInstall{id: install_id, status: :queued, head_sha: ^head_sha}} =
             Tools.ensure_toolchain(project)

    assert {:ok, %ToolchainInstall{id: ^install_id}} = Tools.ensure_toolchain(project)
    assert [%Oban.Job{args: %{"install_id" => ^install_id}}] = all_enqueued(worker: InstallToolchain)
    assert [%ToolchainInstall{id: ^install_id, project: %Project{id: ^project_id}}] = Tools.list_toolchain_installs()

    assert :ok = perform_job(InstallToolchain, %{install_id: install_id})

    assert File.read!(Path.join(tmp_dir, "ran")) == "erlang 28.5.0.7\n"

    assert %ToolchainInstall{status: :finished, started_at: %DateTime{}, ended_at: %DateTime{}} =
             Repo.get!(ToolchainInstall, install_id)

    assert [] = Tools.list_toolchain_installs()

    # Already run for this commit, so the next fetch asks for nothing.
    assert {:ok, %ToolchainInstall{id: ^install_id}} = Tools.ensure_toolchain(project)
    assert [_only] = all_enqueued(worker: InstallToolchain)
    assert {:error, :not_queued} = Tools.install_toolchain(install_id)
  end

  test "a failed command is reported with what it wrote, and is tried again only when asked", %{project: project} do
    {:ok, project} =
      Projects.update_project(system_scope(), project, %{toolchain_command: "echo 'kerl: build failed'; exit 1"})

    assert {:ok, %ToolchainInstall{id: install_id}} = Tools.ensure_toolchain(project)

    assert {:ok, %ToolchainInstall{status: :failed, output: "kerl: build failed\n"} = failed} =
             Tools.install_toolchain(install_id)

    assert [%ToolchainInstall{id: ^install_id, status: :failed}] = Tools.list_toolchain_installs()

    assert {:ok, %ToolchainInstall{id: ^install_id}} = Tools.ensure_toolchain(project)
    assert {:error, :not_authorized} = Tools.retry_toolchain_install(user_scope(), failed)
    assert [_first] = all_enqueued(worker: InstallToolchain)

    assert {:ok, %ToolchainInstall{id: retried_id, status: :queued}} =
             Tools.retry_toolchain_install(system_scope(), failed)

    assert retried_id != install_id
    assert_enqueued(worker: InstallToolchain, args: %{install_id: retried_id})

    # The retry is the project's latest, so the failure it replaces is no longer shown.
    assert [%ToolchainInstall{id: ^retried_id}] = Tools.list_toolchain_installs()
    assert {:ok, %ToolchainInstall{id: ^retried_id}} = Tools.retry_toolchain_install(system_scope(), failed)

    {:ok, _project} = Projects.update_project(system_scope(), project, %{toolchain_command: ""})
    assert {:error, :no_command} = Tools.retry_toolchain_install(system_scope(), failed)
  end

  test "a default branch that cannot be checked out fails the install with what git said", %{
    project: project,
    clone: clone
  } do
    assert {:ok, %ToolchainInstall{id: install_id}} = Tools.ensure_toolchain(project)
    git!(clone, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert {:ok, %ToolchainInstall{status: :failed, output: "" <> _what_git_said}} = Tools.install_toolchain(install_id)
  end

  test "a project with no command, or no fetched default branch, has nothing queued", %{project: project} do
    assert :ok = Tools.ensure_toolchain(%{project | toolchain_command: nil})
    assert :ok = Tools.ensure_toolchain(%{project | toolchain_command: ""})
    assert :ok = Tools.ensure_toolchain(%{project | default_branch: "never-fetched"})
    assert [] = all_enqueued(worker: InstallToolchain)
  end
end
