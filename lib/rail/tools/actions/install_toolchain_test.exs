defmodule Rail.Tools.Actions.InstallToolchainTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools
  alias Rail.Tools.Schemas.ToolchainInstall
  alias Rail.Tools.Workers.InstallToolchain

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "install_toolchain_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    id = System.unique_integer([:positive])
    # Only checked out from, never read, so the clone is a path under the test's directory.
    clone = Path.join(tmp_dir, "clone")
    head_sha = Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    # Which commit the fetched default branch is at is asked of git directly, not through `Rail.Git`.
    stub(Tools, :run, fn
      "git", ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"], [cd: ^clone] -> {head_sha <> "\n", 0}
      "git", ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" <> _unfetched], [cd: ^clone] -> {"", 1}
      executable, args, opts -> call_original(Tools, :run, [executable, args, opts])
    end)

    stub(Git, :checkout_detached_worktree, fn _project, path ->
      File.mkdir_p!(path)
      {:ok, path}
    end)

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

    %{project: project, tmp_dir: tmp_dir, head_sha: head_sha}
  end

  test "the command runs once for a commit of the default branch, in a checkout of it", %{
    project: %Project{id: project_id} = project,
    tmp_dir: tmp_dir,
    head_sha: head_sha
  } do
    checkout_path = ToolchainInstall.checkout_path(project)

    expect(Git, :checkout_detached_worktree, fn %Project{id: ^project_id}, ^checkout_path ->
      File.mkdir_p!(checkout_path)
      File.write!(Path.join(checkout_path, ".tool-versions"), "erlang 28.5.0.7\n")
      {:ok, checkout_path}
    end)

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

  test "a default branch that cannot be checked out fails the install with what git said", %{project: project} do
    assert {:ok, %ToolchainInstall{id: install_id}} = Tools.ensure_toolchain(project)

    expect(Git, :checkout_detached_worktree, fn _project, _path ->
      {:error, "fatal: unable to access '/tmp/nowhere/': Could not resolve host"}
    end)

    assert {:ok,
            %ToolchainInstall{status: :failed, output: "fatal: unable to access '/tmp/nowhere/': Could not resolve host"}} =
             Tools.install_toolchain(install_id)
  end

  test "a project with no command, or no fetched default branch, has nothing queued", %{project: project} do
    assert :ok = Tools.ensure_toolchain(%{project | toolchain_command: nil})
    assert :ok = Tools.ensure_toolchain(%{project | toolchain_command: ""})
    assert :ok = Tools.ensure_toolchain(%{project | default_branch: "never-fetched"})
    assert [] = all_enqueued(worker: InstallToolchain)
  end
end
