defmodule Rail.Git.Actions.SaveEnvFileTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  # Each project has a clone of its own: a .env in the shared test project's would reach other tests' worktrees.
  setup do
    projects =
      for {name, script} <- [scripted: "scripts/setup.sh", unscripted: nil, other: "scripts/setup.sh"], into: %{} do
        unique = System.unique_integer([:positive])
        clone = create_temp_git_repo(prefix: "rail_env_#{name}")

        {:ok, %Project{} = project} =
          Projects.create_project(system_scope(), %{
            name: "Env #{name}",
            github_repo: "example/env-#{name}-#{unique}",
            github_installation_id: 1,
            key: "env#{unique}",
            default_branch: "main",
            clone_path: clone,
            worktree_setup_script: script
          })

        {name, project}
      end

    # Each task's worktree, by the state it is in: set up, still waiting on its script, or cleaned up.
    worktrees =
      for {key, project_name, attrs} <- [
            {:set_up, :scripted, %{worktree_setup_at: DateTime.utc_now()}},
            {:waiting, :scripted, %{}},
            {:cleaned_up, :scripted, %{worktree_setup_at: DateTime.utc_now(), cleaned_up_at: DateTime.utc_now()}},
            {:unscripted, :unscripted, %{}},
            {:other, :other, %{worktree_setup_at: DateTime.utc_now()}}
          ],
          into: %{} do
        %Project{id: project_id, clone_path: clone} = projects[project_name]
        branch = "env-#{key}-#{System.unique_integer([:positive])}"
        path = Path.join(clone, ".worktrees/#{branch}")
        git!(clone, ["worktree", "add", "-b", branch, path])

        issue =
          Repo.insert!(
            Issue.changeset(%Issue{}, %{
              project_id: project_id,
              external_id: "I_#{branch}",
              identifier: branch,
              title: branch,
              state: :backlog
            })
          )

        %Task{}
        |> Task.changeset(
          Map.merge(
            %{issue_id: issue.id, stage: :engineer, worktree_name: branch, worktree_path: path, scratch_path: path},
            attrs
          ),
          project_id
        )
        |> Repo.insert!()

        {key, path}
      end

    %{projects: projects, worktrees: worktrees}
  end

  test "a set-up worktree keeps its own lines and holds only the project's value for the project's variables", %{
    projects: %{scripted: project},
    worktrees: %{set_up: worktree}
  } do
    File.write!(Path.join(worktree, ".env"), """
    # >>> setup-worktree managed block (slot 1001) >>>
    WORKTREE_SLOT=1001
    PORT=4100
    # <<< setup-worktree managed block <<<

    # Mine
    export API_KEY=stale
    OWN=mine
    """)

    assert {:ok, 1} = Git.save_env_file(project, "API_KEY=new\nFOO=\"two words\"\n")

    written = """
    # >>> Rail: the project's .env, rewritten on every save >>>
    API_KEY=new
    FOO="two words"
    # <<< Rail: the project's .env <<<
    # >>> setup-worktree managed block (slot 1001) >>>
    WORKTREE_SLOT=1001
    PORT=4100
    # <<< setup-worktree managed block <<<

    # Mine
    OWN=mine
    """

    assert File.read!(Path.join(worktree, ".env")) == written
    assert File.read!(Path.join(project.clone_path, ".env")) == "API_KEY=new\nFOO=\"two words\"\n"

    assert {:ok, 1} = Git.save_env_file(project, "API_KEY=new\nFOO=\"two words\"\n")
    assert File.read!(Path.join(worktree, ".env")) == written

    assert {:ok, 1} = Git.save_env_file(project, "FOO=three\n")
    assert File.read!(Path.join(worktree, ".env")) =~ ~r/\A# >>> Rail[^\n]*\nFOO=three\n# <<< Rail/
    refute File.read!(Path.join(worktree, ".env")) =~ "API_KEY"
  end

  test "a block a setup script rerun moved below its own is replaced where it is, not written twice", %{
    projects: %{scripted: project},
    worktrees: %{set_up: worktree}
  } do
    File.write!(Path.join(worktree, ".env"), """
    PORT=4100
    # >>> Rail: the project's .env, rewritten on every save >>>
    FOO=old
    # <<< Rail: the project's .env <<<
    """)

    assert {:ok, 1} = Git.save_env_file(project, "FOO=new\n")

    assert File.read!(Path.join(worktree, ".env")) == """
           # >>> Rail: the project's .env, rewritten on every save >>>
           FOO=new
           # <<< Rail: the project's .env <<<
           PORT=4100
           """
  end

  test "only the project's set-up worktrees are written, and git never lists the file", %{
    projects: %{scripted: project, other: other},
    worktrees: worktrees
  } do
    File.write!(Path.join(worktrees.other, ".env"), "OTHER=1\n")

    assert {:ok, 1} = Git.save_env_file(project, "FOO=bar\n")

    assert File.read!(Path.join(worktrees.set_up, ".env")) =~ "\nFOO=bar\n"
    assert git!(worktrees.set_up, ["status", "--porcelain"]) == ""
    refute File.exists?(Path.join(worktrees.waiting, ".env"))
    refute File.exists?(Path.join(worktrees.cleaned_up, ".env"))
    assert File.read!(Path.join(worktrees.other, ".env")) == "OTHER=1\n"
    refute File.exists?(Path.join(other.clone_path, ".env"))
  end

  test "a worktree of a project with no setup script is set up as soon as it is made", %{
    projects: %{unscripted: project},
    worktrees: %{unscripted: worktree}
  } do
    File.rm_rf!(Path.join(project.clone_path, ".git/info"))

    assert {:ok, 1} = Git.save_env_file(project, "FOO=bar\n")
    assert File.read!(Path.join(worktree, ".env")) =~ "\nFOO=bar\n"
    assert File.read!(Path.join(project.clone_path, ".git/info/exclude")) == "/.env\n"
  end

  test "a worktree whose directory is gone is skipped", %{projects: %{scripted: project}, worktrees: worktrees} do
    git!(project.clone_path, ["worktree", "remove", "--force", worktrees.set_up])

    assert {:ok, 0} = Git.save_env_file(project, "FOO=bar\n")
  end

  test "a clone whose .env cannot be written writes no worktree", %{
    projects: %{scripted: project},
    worktrees: %{set_up: worktree}
  } do
    File.mkdir_p!(Path.join(project.clone_path, ".env"))
    File.write!(Path.join(worktree, ".env"), "OWN=mine\n")

    assert {:error, :eisdir} = Git.save_env_file(project, "FOO=bar\n")
    assert File.read!(Path.join(worktree, ".env")) == "OWN=mine\n"
  end
end
