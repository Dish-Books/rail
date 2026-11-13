defmodule Rail.Issues.Actions.FindIssue do
  @moduledoc false

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  @doc """
  The ticket `identifier` names, such as `RAIL-12`, `rail-12` or `rail#12`, in one of the scope's projects. Its key
  picks the project and its trailing digits the number; a ticket Rail has not mirrored is brought in from the tracker.

  Options: `:preload`, to which `:project` is always added. Anything else, a project the scope cannot open included,
  is `{:error, :not_found}`.
  """
  def find_issue(scope, identifier, opts \\ []) when is_binary(identifier) and is_list(opts) do
    with [_identifier, key, number] <- Regex.run(~r/\A(.+)[-#](\d+)\z/, String.trim(identifier)),
         {:ok, %Project{} = project} <- Projects.find_project(scope, key),
         {:ok, %Issue{id: id}} <- Issues.import_issue(project, canonical(project, String.to_integer(number))) do
      Issues.get_issue(id, preload: Enum.uniq([:project | Keyword.get(opts, :preload, [])]))
    else
      _not_found -> {:error, :not_found}
    end
  end

  defp canonical(%Project{tracker: :github, key: key}, number), do: "#{key}##{number}"
  defp canonical(%Project{key: key}, number), do: "#{key}-#{number}"
end
