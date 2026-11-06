defmodule Rail.Roles.Utils.LoadPromptsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    id = System.unique_integer([:positive])

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Load Prompts #{id}",
        github_repo: "org/load-prompts-#{id}",
        github_installation_id: id,
        key: "LP#{id}",
        default_branch: "main",
        clone_path: "/tmp/repos/load-prompts-#{id}"
      })
      |> Repo.insert!()

    {:ok, engineer} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
        stage: :engineer,
        name: "Engineer",
        model: "claude-opus-5-5",
        system_prompt: "Stored engineer prompt."
      })

    %{project: project, engineer: engineer}
  end

  # Only the stage's own `.rail/prompts/<stage>.md` on the default branch is asked for, so a file
  # anywhere else, or only on an unmerged branch, is never read.
  test "the stage's .rail/prompts file on the default branch becomes the role's prompt, named by its path, less exactly one trailing newline, and is never written to the role's row",
       %{project: %{id: project_id}, engineer: engineer} do
    expect(Git, :read_default_branch_file, fn %Project{id: ^project_id}, ".rail/prompts/engineer.md" ->
      {:ok, "Line one.\n\nLine two.\n\n"}
    end)

    assert {:ok, %Role{system_prompt: "Line one.\n\nLine two.\n", prompt_path: ".rail/prompts/engineer.md"}} =
             Roles.get_role(id: engineer.id)

    assert %Role{system_prompt: "Stored engineer prompt."} = Repo.get!(Role, engineer.id)
  end

  # Git answers a file the default branch does not have, never had or has since deleted, with an error.
  test "leaves a role whose stage has no file on the default branch, or no stage at all, as stored", %{
    project: project
  } do
    {:ok, _custom} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
        name: "Custom",
        position: 1,
        model: "claude-opus-5-5",
        system_prompt: "Stored custom prompt."
      })

    expect(Git, :read_default_branch_file, fn _project, ".rail/prompts/engineer.md" = path ->
      {:error, "fatal: path '#{path}' does not exist in 'refs/remotes/origin/main'"}
    end)

    assert [
             %Role{system_prompt: "Stored engineer prompt.", prompt_path: nil},
             %Role{system_prompt: "Stored custom prompt.", prompt_path: nil}
           ] = Roles.list_roles(project.id)
  end

  test "falls back to the stored prompt, never a blank one, when the file on the default branch is empty", %{
    engineer: engineer
  } do
    expect(Git, :read_default_branch_file, fn _project, ".rail/prompts/engineer.md" -> {:ok, " \n\n"} end)

    assert {:ok, %Role{system_prompt: "Stored engineer prompt.", prompt_path: nil}} = Roles.get_role(id: engineer.id)
  end

  test "each project loads only the prompts in its own repo", %{project: %{id: project_id} = project} do
    %Project{id: other_project_id} =
      other_project =
      %Project{}
      |> Project.changeset(%{
        name: "Other #{project.name}",
        github_repo: "#{project.github_repo}-other",
        github_installation_id: project.github_installation_id,
        key: "#{project.key}O",
        default_branch: "main",
        clone_path: "#{project.clone_path}-other"
      })
      |> Repo.insert!()

    {:ok, _other_engineer} =
      Roles.create_role(system_scope(), other_project, %{
        cli: :claude,
        stage: :engineer,
        name: "Engineer",
        model: "claude-opus-5-5",
        system_prompt: "Stored other prompt."
      })

    expect(Git, :read_default_branch_file, 2, fn
      %Project{id: ^project_id}, ".rail/prompts/engineer.md" -> {:ok, "First project.\n"}
      %Project{id: ^other_project_id}, ".rail/prompts/engineer.md" -> {:ok, "Second project.\n"}
    end)

    assert {[%Role{system_prompt: "First project."}], [%Role{system_prompt: "Second project."}]} =
             {Roles.list_roles(project.id), Roles.list_roles(other_project.id)}
  end
end
