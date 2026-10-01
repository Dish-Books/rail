defmodule Rail.Roles.Actions.LoadPrompts do
  @moduledoc false

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles.Schemas.Role

  @doc """
  Returns `roles` with each stage's `.rail/prompts/<stage>.md`, as merged on
  `project`'s default branch, in place of its stored prompt, and `prompt_path`
  naming that file. A role with no such file, or a blank one, keeps its stored
  prompt, so a run never gets an empty one. Nothing is written back.
  """
  def load_prompts(%Project{} = project, roles) when is_list(roles) do
    Enum.map(roles, &load_prompt(project, &1))
  end

  defp load_prompt(%Project{id: project_id}, %Role{project_id: project_id, stage: nil} = role), do: role

  defp load_prompt(%Project{id: project_id} = project, %Role{project_id: project_id, stage: stage} = role) do
    path = ".rail/prompts/#{stage}.md"

    with {:ok, text} <- Git.read_default_branch_file(project, path),
         false <- String.trim(text) == "" do
      # One trailing newline is the file's own, not the prompt's.
      %{role | system_prompt: String.replace_suffix(text, "\n", ""), prompt_path: path}
    else
      _missing_or_blank -> role
    end
  end
end
