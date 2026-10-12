defmodule Rail.Repo.Migrations.AddCiReservedCpusToProjects do
  use Ecto.Migration

  # CI held its engineer role's CPUs until now, so each project starts at that number and no CI run changes.
  def change do
    alter table(:projects) do
      add :ci_reserved_cpus, :integer, null: false, default: 1
    end

    execute(
      """
      UPDATE projects SET ci_reserved_cpus = roles.reserved_cpus
      FROM roles WHERE roles.project_id = projects.id AND roles.stage = 'engineer'
      """,
      ""
    )
  end
end
