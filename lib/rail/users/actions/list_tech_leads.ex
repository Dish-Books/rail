defmodule Rail.Users.Actions.ListTechLeads do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Lists the tech leads who can open the project with `project_id`, by name, so Finalize can say whom to ask.
  """
  def list_tech_leads(project_id) when is_binary(project_id) do
    User
    |> where([u], u.tech_lead and (u.admin or ^project_id in u.project_ids))
    |> order_by([u], asc: u.name, asc: u.login)
    |> Repo.all()
  end
end
