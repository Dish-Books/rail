defmodule Rail.Pipeline.Utils.MergeBaseSection do
  @moduledoc """
  The section Rail puts first on a fix round's plan when the branch would conflict with the default branch, so the
  engineer merges it in before building the rest. Rail adds it itself, whatever a project's prompts say, since a
  branch that conflicts cannot merge.
  """

  @doc """
  Returns `plan` led by the section that merges `origin/<base>` in and counts the `conflicts`, or `plan` as it is
  when nothing conflicts. The files are counted, not listed, since a branch far behind can conflict in a great many.
  """
  def add_merge_base_section(plan, _base, []), do: plan

  def add_merge_base_section(plan, base, conflicts) when is_binary(plan) and is_binary(base) do
    merge_base_section(base, conflicts) <> "\n\n" <> plan
  end

  @doc """
  The section, as its markdown, for a branch that conflicts with `origin/<base>` in `conflicts`.
  """
  def merge_base_section(base, [_first | _rest] = conflicts) do
    String.trim("""
    ### Merge `#{base}` first

    The branch conflicts with `origin/#{base}` in #{files(conflicts)}, so before anything else this round, merge `origin/#{base}` in; git names each conflict as you merge. Resolve each conflict the way both sides meant it: keep what the default branch changed and everything the earlier rounds built, and follow what it changed through the code, tests and comments the branch relies on. Commit the merge on its own, then build the rest of this plan on top of it.
    """)
  end

  @doc """
  How many files conflict, as a phrase: "1 file" or "N files".
  """
  def files([_one]), do: "1 file"
  def files(conflicts) when is_list(conflicts), do: "#{length(conflicts)} files"
end
