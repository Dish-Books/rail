defmodule Rail.Artifacts.Actions.ReadDesign do
  @moduledoc false

  alias Rail.Artifacts.Validators.DesignValidator
  alias Rail.Scope

  def read_design(scope, target, opts \\ []) do
    if authorized?(scope) do
      design_dir = resolve_design_dir(target, opts)
      DesignValidator.validate(design_dir, opts)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp resolve_design_dir(path_or_id, opts) when is_binary(path_or_id) do
    dir = Keyword.get(opts, :scratch_dir, path_or_id)

    cond do
      File.exists?(Path.join(dir, "manifest.json")) ->
        dir

      File.exists?(Path.join([dir, "design", "manifest.json"])) ->
        Path.join(dir, "design")

      File.exists?(Path.join([dir, ".axis", "design", "manifest.json"])) ->
        Path.join([dir, ".axis", "design"])

      true ->
        dir
    end
  end

  defp resolve_design_dir(%{id: task_id}, opts) do
    resolve_design_dir(to_string(task_id), opts)
  end
end
