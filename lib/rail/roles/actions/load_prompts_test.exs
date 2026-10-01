defmodule Rail.Roles.Actions.LoadPromptsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    remote = create_temp_git_repo(prefix: "rail_prompts_remote")
    clone = create_temp_git_repo(prefix: "rail_prompts_clone")
    git!(clone, ["remote", "add", "origin", remote])

    id = System.unique_integer([:positive])

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Load Prompts #{id}",
        github_repo: "org/load-prompts-#{id}",
        github_installation_id: id,
        linear_team_key: "LP#{id}",
        default_branch: "main",
        clone_path: clone
      })
      |> Repo.insert!()

    {:ok, backend} = Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, engineer} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "Engineer",
        model: "claude-opus-5-5",
        system_prompt: "Stored engineer prompt."
      })

    %{project: project, remote: remote, clone: clone, backend: backend, engineer: engineer}
  end

  test "a merged and fetched prompt file becomes the role's prompt, named by its path", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "From the repo.")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    git!(clone, ["fetch", "origin", "main"])

    assert [%Role{system_prompt: "From the repo.", prompt_path: ".rail/prompts/engineer.md"}] =
             Roles.load_prompts(project, [engineer])
  end

  test "drops exactly one trailing newline, so a file written as prompt plus newline reads back as the prompt", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "Line one.\n\nLine two.\n\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    git!(clone, ["fetch", "origin", "main"])

    assert [%Role{system_prompt: "Line one.\n\nLine two.\n"}] = Roles.load_prompts(project, [engineer])
  end

  test "leaves a role with no file for its stage, or no stage at all, as stored", %{
    project: project,
    remote: remote,
    clone: clone,
    backend: backend,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/review.md"), "Review prompt.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add review prompt"])
    git!(clone, ["fetch", "origin", "main"])

    {:ok, custom} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        name: "Custom",
        model: "claude-opus-5-5",
        system_prompt: "Stored custom prompt."
      })

    assert [
             %Role{system_prompt: "Stored engineer prompt.", prompt_path: nil},
             %Role{system_prompt: "Stored custom prompt.", prompt_path: nil}
           ] = Roles.load_prompts(project, [engineer, custom])
  end

  test "leaves every role as stored when the repo has no .rail/prompts folder", %{
    project: project,
    clone: clone,
    engineer: engineer
  } do
    git!(clone, ["fetch", "origin", "main"])

    assert [%Role{system_prompt: "Stored engineer prompt.", prompt_path: nil}] = Roles.load_prompts(project, [engineer])
  end

  test "never writes the file's text to the role's row", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    git!(clone, ["fetch", "origin", "main"])

    Roles.load_prompts(project, [engineer])

    assert %Role{system_prompt: "Stored engineer prompt."} = Repo.get!(Role, engineer.id)
  end

  test "falls back to the stored prompt once a later merge deletes the file", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    git!(remote, ["rm", ".rail/prompts/engineer.md"])
    git!(remote, ["commit", "-m", "remove prompt"])
    git!(clone, ["fetch", "origin", "main"])

    assert [%Role{system_prompt: "Stored engineer prompt.", prompt_path: nil}] = Roles.load_prompts(project, [engineer])
  end

  test "falls back to the stored prompt, never a blank one, once a later merge empties the file", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), " \n\n")
    git!(remote, ["commit", "-am", "empty prompt"])
    git!(clone, ["fetch", "origin", "main"])

    assert [%Role{system_prompt: "Stored engineer prompt.", prompt_path: nil}] = Roles.load_prompts(project, [engineer])
  end

  test "ignores prompt files outside .rail/prompts/<stage>.md", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, "prompts"))
    File.mkdir_p!(Path.join(remote, ".rail/prompts/x"))
    File.write!(Path.join(remote, "prompts/engineer.md"), "Old folder.\n")
    File.write!(Path.join(remote, ".rail/prompts/x/engineer.md"), "Nested.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "prompts elsewhere"])
    git!(clone, ["fetch", "origin", "main"])

    assert [%Role{system_prompt: "Stored engineer prompt.", prompt_path: nil}] = Roles.load_prompts(project, [engineer])
  end

  test "ignores a prompt file committed only on an unmerged branch", %{
    project: project,
    remote: remote,
    clone: clone,
    engineer: engineer
  } do
    git!(remote, ["checkout", "-b", "task-branch"])
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "Unmerged.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "unmerged prompt"])
    git!(clone, ["fetch", "origin", "main", "task-branch"])

    assert [%Role{system_prompt: "Stored engineer prompt.", prompt_path: nil}] = Roles.load_prompts(project, [engineer])
  end

  test "each project loads only the prompts in its own repo", %{
    project: project,
    remote: remote,
    clone: clone,
    backend: backend,
    engineer: engineer
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "First project.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    git!(clone, ["fetch", "origin", "main"])

    other_remote = create_temp_git_repo(prefix: "rail_prompts_other_remote")
    File.mkdir_p!(Path.join(other_remote, ".rail/prompts"))
    File.write!(Path.join(other_remote, ".rail/prompts/engineer.md"), "Second project.\n")
    git!(other_remote, ["add", "."])
    git!(other_remote, ["commit", "-m", "add prompt"])
    other_clone = create_temp_git_repo(prefix: "rail_prompts_other_clone")
    git!(other_clone, ["remote", "add", "origin", other_remote])
    git!(other_clone, ["fetch", "origin", "main"])

    other_project =
      %Project{}
      |> Project.changeset(%{
        name: "Other #{project.name}",
        github_repo: "#{project.github_repo}-other",
        github_installation_id: project.github_installation_id,
        linear_team_key: "#{project.linear_team_key}O",
        default_branch: "main",
        clone_path: other_clone
      })
      |> Repo.insert!()

    {:ok, other_engineer} =
      Roles.create_role(system_scope(), other_project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "Engineer",
        model: "claude-opus-5-5",
        system_prompt: "Stored other prompt."
      })

    assert {[%Role{system_prompt: "First project."}], [%Role{system_prompt: "Second project."}]} =
             {Roles.load_prompts(project, [engineer]), Roles.load_prompts(other_project, [other_engineer])}
  end

  test "refuses a role that belongs to another project", %{project: project, engineer: engineer} do
    assert_raise FunctionClauseError, fn ->
      Roles.load_prompts(%{project | id: "prj_other"}, [engineer])
    end
  end
end
