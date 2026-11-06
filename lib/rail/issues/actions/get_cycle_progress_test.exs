defmodule Rail.Issues.Actions.GetCycleProgressTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Users

  setup %{project: project} do
    users =
      for name <- ["Ana", "Bo", "Cy"] do
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_progress_#{name}",
            login: "progress_#{name}",
            name: name,
            email: "progress_#{name}@example.com"
          })

        user
      end

    insert = fn external_id, cycle, state, estimate, owner ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: external_id,
        identifier: external_id,
        title: external_id,
        state: state,
        estimate: estimate,
        cycle_external_id: cycle,
        owner_user_id: owner && owner.id
      })
      |> Repo.insert!()
    end

    %{users: users, insert: insert}
  end

  test "counts an unestimated issue at the team's default, leaves out canceled ones, and orders owners by points", %{
    project: project,
    users: [%{id: ana_id} = ana, %{id: bo_id} = bo, %{id: cy_id} = cy],
    insert: insert
  } do
    insert.("lin_cp1", "cyc_p", :done, 3, ana)
    insert.("lin_cp2", "cyc_p", :in_progress, nil, ana)
    insert.("lin_cp3", "cyc_p", :in_review, 2, bo)
    insert.("lin_cp4", "cyc_p", :todo, 2, cy)
    insert.("lin_cp5", "cyc_p", :canceled, 8, ana)
    insert.("lin_cp6", "cyc_p", :duplicate, 8, bo)
    insert.("lin_cp7", "cyc_p", :backlog, 1, nil)
    insert.("lin_cp8", "cyc_other", :done, 5, ana)

    cycle = %{id: "cyc_p", default_estimate: 2, scope_history: [8.0, 9.0]}

    # Scope 3 + 2 + 2 + 2 + 1, against 8 on the first day.
    assert %{
             scope: 10,
             started: 7,
             completed: 3,
             scope_change: 25,
             owners: [
               %{user: %{id: ^ana_id}, points: 5, completed: 3},
               # Bo and Cy tie on points, so the name decides.
               %{user: %{id: ^bo_id}, points: 2, completed: 0},
               %{user: %{id: ^cy_id}, points: 2, completed: 0}
             ]
           } = Issues.get_cycle_progress(project, cycle)
  end

  test "a cycle with no history yet has no scope change", %{project: project} do
    assert %{scope: 0, started: 0, completed: 0, scope_change: nil, owners: []} =
             Issues.get_cycle_progress(project, %{id: "cyc_empty", default_estimate: 1, scope_history: []})
  end
end
