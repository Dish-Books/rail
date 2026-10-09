defmodule Rail.Mcp.Utils.RunToolQaFile do
  @moduledoc """
  Files an output file the pass produced, a log, a PDF, a CSV, against one check.

  The agent names a path it wrote under the QA directory and Rail copies it in
  under a name of its own, the way it names a picture. Each refusal answers in a
  sentence the agent can act on, and every one of them ends by saying nothing was
  filed.

  The browser the file came from is named the way every browser tool names one, so the
  finding citing it can say which explorer saw it.
  """

  import Rail.Mcp.Utils.BrowserName

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Files `arguments["path"]` as `arguments["name"]` against the check
  `arguments["check"]` on `task`, from the browser `arguments["browser"]` if it names one,
  and says what it was filed as.
  """
  def run_tool_qa_file(%Task{} = task, %{"check" => check, "name" => name, "path" => path} = arguments, opts)
      when is_binary(check) and is_binary(name) and is_binary(path) do
    # A key no row has would file evidence the panel never shows, while the agent
    # believes the row is evidenced.
    with {:ok, browser} <- browser(arguments, opts),
         {:ok, %QaChecklist{checks: checks}} <- Pipeline.read_qa_checklist(task),
         %QaCheck{} <- Enum.find(checks, &(&1.key == check)),
         {:ok, file} <- Tools.file_qa_evidence(task, path, name, check, browser) do
      {:ok, "Filed as #{file}. Cite that name in the finding's evidence."}
    else
      {:refused, text} ->
        {:refused, text}

      {:error, :qa_checklist_not_found} ->
        {:refused, "There is no checklist yet. Call qa_plan first. Nothing was filed."}

      nil ->
        {:refused, "No check called #{inspect(check)} is on the checklist. Nothing was filed."}

      {:error, :unconfined_path} ->
        {:refused,
         "`path` is relative to the QA directory, never absolute and never climbing out with `..`. " <>
           "Nothing was filed."}

      {:error, :unusable_name} ->
        {:refused,
         "Rename it to letters, digits, `.`, `_`, `-`, `~` and `/` only, then file it again. Nothing was filed."}

      {:error, :not_a_file} ->
        {:refused, "No file at #{path}. Nothing was filed."}
    end
  end

  def run_tool_qa_file(%Task{}, _arguments, _opts) do
    {:refused, "qa_file needs a `check`, a `name` and a `path`. Nothing was filed."}
  end

  # A file need not come from a browser at all, so only a name given is checked.
  defp browser(%{"browser" => _given} = arguments, opts) do
    case browser_name(arguments, opts) do
      {:ok, name} -> {:ok, name}
      {:refused, text} -> {:refused, text <> " Nothing was filed."}
    end
  end

  defp browser(_arguments, _opts), do: {:ok, nil}
end
