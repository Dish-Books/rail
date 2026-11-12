defmodule Rail.Issues.Utils.MarkLabelledTested do
  @moduledoc """
  Moves the Linear tickets labeled Test done or Technical out of the testing queue, as Linear reports them.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @labels ["test done", "technical"]

  @doc """
  Marks Tested the Waiting or In testing tickets of `project` among `nodes`, as the API or a webhook sends them, that
  carry either label in any case. Returns how many moved; a Sent to triage or Tested ticket keeps its state.
  """
  def mark_labelled_tested(%Project{id: project_id}, nodes) do
    case for(node <- nodes, Enum.any?(label_names(node), &(&1 in @labels)), do: node["id"]) do
      [] ->
        0

      labeled ->
        {count, nil} =
          Repo.update_all(
            from(i in Issue,
              where: i.project_id == ^project_id and i.external_id in ^labeled,
              where: i.testing_state in ^[:waiting, :testing]
            ),
            set: [testing_state: :tested, updated_at: DateTime.utc_now(:second)]
          )

        count
    end
  end

  # The API nests labels under nodes; a webhook sends a plain list.
  defp label_names(%{"labels" => %{"nodes" => labels}}) when is_list(labels), do: names(labels)
  defp label_names(%{"labels" => labels}) when is_list(labels), do: names(labels)
  defp label_names(_no_labels), do: []

  defp names(labels),
    do: for(%{"name" => name} when is_binary(name) <- labels, do: name |> String.trim() |> String.downcase())
end
