defmodule Rail.Mcp.Utils.RunToolQaFile do
  @moduledoc """
  Files an output file the pass produced, a log, a PDF, a CSV, against one check.

  The agent names a path it wrote under the QA directory and Rail copies it in
  under a name of its own, the way it names a picture. Nothing an agent can get
  wrong is an error here: each refusal answers in a sentence it can act on.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Files `arguments["path"]` as `arguments["name"]` against the check
  `arguments["check"]` on `task`, and says what it was filed as.
  """
  def run_tool_qa_file(%Task{} = task, %{"check" => check, "name" => name, "path" => path}, _opts)
      when is_binary(check) and is_binary(name) and is_binary(path) do
    case Tools.file_qa_evidence(task, path, name, check) do
      {:ok, file} ->
        {:ok, "Filed as #{file}. Cite that name in the finding's evidence."}

      {:error, :unconfined_path} ->
        {:ok,
         "`path` is relative to the QA directory, never absolute and never climbing out with `..`. " <>
           "Nothing was filed."}

      {:error, :not_a_file} ->
        {:ok, "No file at #{path}. Nothing was filed."}
    end
  end

  def run_tool_qa_file(%Task{}, _arguments, _opts) do
    {:ok, "qa_file needs a `check`, a `name` and a `path`."}
  end
end
