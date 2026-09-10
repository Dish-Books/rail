defmodule Rail.Artifacts.Actions.ReadDemo do
  @moduledoc false

  alias Rail.Artifacts.Validators.DemoValidator

  def read_demo(_scope, target, opts \\ []) do
    demo_dir = resolve_demo_dir(target, opts)
    DemoValidator.validate(demo_dir, opts)
  end

  defp resolve_demo_dir(%{worktree_path: path}, opts) when is_binary(path) and path != "" do
    dir = Keyword.get(opts, :scratch_dir, path)
    resolve_demo_dir(dir, opts)
  end

  defp resolve_demo_dir(path_or_id, opts) when is_binary(path_or_id) do
    dir = Keyword.get(opts, :scratch_dir, path_or_id)

    cond do
      File.exists?(Path.join(dir, "manifest.json")) ->
        dir

      File.exists?(Path.join([dir, "demo", "manifest.json"])) ->
        Path.join(dir, "demo")

      File.exists?(Path.join([dir, ".axis", "demo", "manifest.json"])) ->
        Path.join([dir, ".axis", "demo"])

      true ->
        dir
    end
  end

  defp resolve_demo_dir(%{id: task_id}, opts) do
    resolve_demo_dir(to_string(task_id), opts)
  end
end
