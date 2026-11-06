defmodule Rail.Projects.Actions.SaveEnvFileTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  setup do
    # The .env is a plain file in the clone, so the clone is a plain directory.
    clone = Path.join(System.tmp_dir!(), "rail_save_env_clone_#{System.unique_integer([:positive])}")
    File.mkdir_p!(clone)
    on_exit(fn -> File.rm_rf(clone) end)
    File.write!(Path.join(clone, ".env"), "OLD=1\n")

    %{project: %Project{id: "prj_save_env_file_test", clone_path: clone}}
  end

  test "an admin saves the rows as one NAME=value line each, in order", %{project: project} do
    assert {:ok, %{written: 0, refused: []}} =
             Projects.save_env_file(temp_user_scope(admin: true), project, %{
               "variables" => %{
                 "0" => %{"name" => "ZED", "value" => "\"quoted\""},
                 "1" => %{"name" => "ALPHA", "value" => ""}
               }
             })

    assert File.read!(Path.join(project.clone_path, ".env")) == "ZED=\"quoted\"\nALPHA=\n"
  end

  test "rows with a repeated name are refused and nothing is written", %{project: project} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Projects.save_env_file(temp_user_scope(admin: true), project, %{
               "variables" => %{"0" => %{"name" => "FOO", "value" => "1"}, "1" => %{"name" => "FOO", "value" => "2"}}
             })

    assert %{variables: [%{}, %{name: ["FOO is already set above"]}]} = errors_on(changeset)
    assert File.read!(Path.join(project.clone_path, ".env")) == "OLD=1\n"
  end

  test "someone who is not an admin cannot save it", %{project: project} do
    assert {:error, :not_authorized} =
             Projects.save_env_file(temp_user_scope(admin: false), project, %{
               "variables" => %{"0" => %{"name" => "FOO", "value" => "1"}}
             })

    assert File.read!(Path.join(project.clone_path, ".env")) == "OLD=1\n"
  end
end
