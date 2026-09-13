defmodule Rail.Artifacts.Utils.PathConfinement do
  @moduledoc false

  @doc """
  Verifies that `target_path` is confined strictly inside `root_dir`.
  If `allow_root: true` is passed, `target_path == root_dir` is accepted.
  Returns `{:ok, canonical_path}` if confined, or `{:error, :escapes_confinement}`.
  """
  def verify_confinement(root_dir, target_path, opts \\ []) when is_binary(root_dir) and is_binary(target_path) do
    canonical_root = Path.expand(root_dir)
    prefix = if String.ends_with?(canonical_root, "/"), do: canonical_root, else: canonical_root <> "/"

    canonical_target =
      if Path.type(target_path) == :absolute do
        Path.expand(target_path)
      else
        Path.expand(target_path, canonical_root)
      end

    allow_root = Keyword.get(opts, :allow_root, false)

    check_confinement(canonical_root, canonical_target, prefix, allow_root)
  end

  defp check_confinement(canonical_root, canonical_target, _prefix, true) when canonical_target == canonical_root do
    {:ok, canonical_target}
  end

  defp check_confinement(canonical_root, canonical_target, prefix, _allow_root) do
    if String.starts_with?(canonical_target, prefix) and canonical_target != canonical_root do
      {:ok, canonical_target}
    else
      {:error, :escapes_confinement}
    end
  end
end
