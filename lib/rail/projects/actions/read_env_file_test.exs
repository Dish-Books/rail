defmodule Rail.Projects.Actions.ReadEnvFileTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.EnvFile
  alias Rail.Projects.Schemas.EnvFile.Variable
  alias Rail.Projects.Schemas.Project

  setup do
    %{project: %Project{clone_path: create_temp_git_repo(prefix: "rail_read_env_clone")}}
  end

  test "an admin reads the variables the clone's .env sets", %{project: project} do
    File.write!(Path.join(project.clone_path, ".env"), "# Secrets\nFOO=bar\nexport BAZ='q'\n")

    assert %EnvFile{variables: [%Variable{name: "FOO", value: "bar"}, %Variable{name: "BAZ", value: "'q'"}]} =
             Projects.read_env_file(temp_user_scope(admin: true), project)
  end

  test "a clone with no .env has no variables", %{project: project} do
    assert %EnvFile{variables: []} = Projects.read_env_file(temp_user_scope(admin: true), project)
  end

  test "bytes that are not UTF-8 read as replaced rather than crash", %{project: project} do
    File.write!(Path.join(project.clone_path, ".env"), <<"FOO=a", 0xFF, "b\n">>)

    assert %EnvFile{variables: [%Variable{name: "FOO", value: "a�b"}]} =
             Projects.read_env_file(temp_user_scope(admin: true), project)
  end

  test "someone who is not an admin cannot read it", %{project: project} do
    File.write!(Path.join(project.clone_path, ".env"), "FOO=bar\n")

    assert {:error, :not_authorized} = Projects.read_env_file(temp_user_scope(admin: false), project)
  end
end
