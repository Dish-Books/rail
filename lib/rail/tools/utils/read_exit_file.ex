defmodule Rail.Tools.Utils.ReadExitFile do
  @moduledoc false

  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Reads the status a command process wrote as it exited, or nil if it never did.

  The port that reports an exit status dies with the BEAM, so this file is how a
  command's result survives a restart.
  """
  def read_exit_file(%OsProcess{} = os_process) do
    with {:ok, content} <- File.read(OsProcess.exit_path(os_process)),
         {code, _rest} <- content |> String.trim() |> Integer.parse() do
      code
    else
      _missing_or_garbled -> nil
    end
  end
end
