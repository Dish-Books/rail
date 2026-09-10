defmodule Rail.Artifacts.Actions.ReadQaReport do
  @moduledoc false

  alias Rail.Artifacts.Validators.QaValidator

  def read_qa_report(_scope, target, opts \\ []) do
    qa_dir = resolve_qa_dir(target, opts)
    QaValidator.validate(qa_dir, opts)
  end

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

      File.exists?(Path.join([dir, ".rail", "qa", "manifest.json"])) ->
        Path.join([dir, ".rail", "qa"])

      true ->
        dir
    end
  end

  defp resolve_qa_dir(%{id: task_id}, opts) do
    resolve_qa_dir(to_string(task_id), opts)
  end
end
