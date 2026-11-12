defmodule Rail.Projects.Actions.SwitchToLocalTrackerTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    project =
      Repo.insert!(%Project{
        name: "Switch Project",
        github_repo: "org/switch-project",
        github_installation_id: 1,
        default_branch: "main",
        key: "swt",
        linear_team_id: "lin_team_swt",
        linear_state_ids: %{"todo" => "st_todo"},
        linear_workspace_id: "lw_test_seed",
        clone_path: "/tmp/repos/switch-project"
      })

    %{project: project}
  end

  test "moves a project with issues onto Rail under the key given, off its Linear team", %{
    project: %Project{id: project_id} = project
  } do
    %Issue{}
    |> Issue.tracker_changeset(%{
      project_id: project_id,
      external_id: "lin_swt_1",
      identifier: "SWT-1",
      title: "Already here",
      state: :todo
    })
    |> Repo.insert!()

    assert {:ok,
            %Project{
              id: ^project_id,
              tracker: :local,
              key: "SWT",
              linear_team_id: nil,
              linear_state_ids: %{},
              linear_workspace_id: nil
            }} = Projects.switch_to_local_tracker(project, "SWT")

    assert %Project{tracker: :local, key: "SWT", linear_workspace_id: nil} = Repo.get!(Project, project_id)
  end

  test "refuses a key another project already has", %{project: project} do
    assert {:error, changeset} = Projects.switch_to_local_tracker(project, "TST")
    assert %{key: ["has already been taken"]} = errors_on(changeset)
    assert %Project{tracker: :linear, key: "swt"} = Repo.get!(Project, project.id)
  end
end
