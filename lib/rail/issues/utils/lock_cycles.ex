defmodule Rail.Issues.Utils.LockCycles do
  @moduledoc """
  The lock both writers of a project's cycles take, so an edit and the daily job never work from what the other is
  about to change.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Repo

  @doc """
  Inside a transaction, waits for the project's cycle lock and returns its cycles as they read once it is held, oldest
  first.
  """
  def lock_cycles(project_id) do
    # Keyed as the numbering trigger keys its lock, on this table and the project, clear of every other advisory lock.
    Repo.query!("SELECT pg_advisory_xact_lock('cycles'::regclass::int, hashtext($1))", [project_id])
    Repo.all(from(c in Cycle, where: c.project_id == ^project_id, order_by: [asc: c.starts_on, asc: c.number]))
  end
end
