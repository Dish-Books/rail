defmodule Rail.Artifacts.Actions.ReadQaReport do
  @moduledoc false

  alias Rail.Artifacts.Validators.QaValidator
  alias Rail.Scope

  def read_qa_report(scope, target, opts \\ []) do
    if authorized?(scope) do
      qa_dir = resolve_qa_dir(target, opts)
      QaValidator.validate(qa_dir, opts)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp resolve_qa_dir(%{worktree_path: path}, opts) when is_binary(path) and path != "" do
    dir = Keyword.get(opts, :scratch_dir, path)
    resolve_qa_dir(dir, opts)
  end

  defp resolve_qa_dir(path_or_id, opts) when is_binary(path_or_id) do
    dir = Keyword.get(opts, :scratch_dir, path_or_id)

    cond do
      File.exists?(Path.join(dir, "manifest.json")) ->
        dir

      File.exists?(Path.join([dir, "qa", "manifest.json"])) ->
        Path.join(dir, "qa")

      File.exists?(Path.join([dir, ".axis", "qa", "manifest.json"])) ->
        Path.join([dir, ".axis", "qa"])

      true ->
        dir
    end
  end

  defp resolve_qa_dir(%{id: task_id}, opts) do
    resolve_qa_dir(to_string(task_id), opts)
  end
end
