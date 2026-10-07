defmodule Rail.Repo.Migrations.AddRevisedAtToImplementationPlans do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:implementation_plans) do
      add :plan_revised_at, :utc_datetime_usec
      add :ticket_revised_at, :utc_datetime_usec
      add :announced_at, :utc_datetime_usec
    end
  end
end
